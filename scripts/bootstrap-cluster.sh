#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

K8S_VERSION="${K8S_VERSION:-1.31}"
CILIUM_VERSION="${CILIUM_VERSION:-1.16.5}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SSH_USER="${SSH_USER:-root}"

CONTROL_PLANE=""
ENDPOINT=""
CONTROL_PLANES_CSV=""
WORKERS_CSV=""
ROUTER_PEER=""
ROUTER_ASN="65000"
CLUSTER_ASN="65001"
LB_POOL_PUBLIC="198.51.100.0/24"
LB_POOL_PRIVATE="203.0.113.0/24"

usage() {
  cat <<EOF
Usage:
  $0 --control-plane <IP> --endpoint <IP> --control-planes <IP,IP> --workers <IP,IP,IP> [options]

Options:
  --endpoint <IP>                 Load balancer IP for the HA API endpoint
  --control-planes <IP,IP>        Additional control plane nodes
  --workers <IP,IP,IP>            Worker nodes
  --ssh-user <USER>               SSH user for remote nodes
  --router-peer <IP>              FRR peer IP
  --router-asn <ASN>              Upstream router ASN
  --cluster-asn <ASN>             Kubernetes nodes ASN
  --lb-pool-public <CIDR>         Cilium public LB pool
  --lb-pool-private <CIDR>        Cilium private LB pool

Example:
  $0 --control-plane 10.0.0.10 --endpoint 10.0.0.14 --control-planes 10.0.0.15,10.0.0.16 --workers 10.0.0.21,10.0.0.22,10.0.0.23 --router-peer 192.0.2.10
EOF
}

log() {
  echo -e "${GREEN}[+] $*${NC}"
}

warn() {
  echo -e "${YELLOW}[!] $*${NC}"
}

fail() {
  echo -e "${RED}[x] $*${NC}" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-plane) CONTROL_PLANE="${2:-}"; shift 2 ;;
    --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
    --control-planes) CONTROL_PLANES_CSV="${2:-}"; shift 2 ;;
    --workers) WORKERS_CSV="${2:-}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --router-peer) ROUTER_PEER="${2:-}"; shift 2 ;;
    --router-asn) ROUTER_ASN="${2:-}"; shift 2 ;;
    --cluster-asn) CLUSTER_ASN="${2:-}"; shift 2 ;;
    --lb-pool-public) LB_POOL_PUBLIC="${2:-}"; shift 2 ;;
    --lb-pool-private) LB_POOL_PRIVATE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$CONTROL_PLANE" ]] || fail "--control-plane is required"
[[ -n "$ENDPOINT" ]] || fail "--endpoint is required"
[[ -n "$CONTROL_PLANES_CSV" ]] || fail "--control-planes is required"
[[ -n "$WORKERS_CSV" ]] || fail "--workers is required"

IFS=',' read -r -a CONTROL_PLANES <<< "$CONTROL_PLANES_CSV"
IFS=',' read -r -a WORKERS <<< "$WORKERS_CSV"

run_remote() {
  local host=$1
  shift
  ssh -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "$@"
}

prepare_node() {
  local node_ip=$1
  log "Preparing node ${node_ip}"

  run_remote "$node_ip" "sudo K8S_VERSION='${K8S_VERSION}' bash -s" <<'REMOTE_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

swapoff -a
sed -i '/swap/d' /etc/fstab

tee /etc/modules-load.d/k8s.conf >/dev/null <<MOD
overlay
br_netfilter
MOD

modprobe overlay
modprobe br_netfilter

tee /etc/sysctl.d/k8s.conf >/dev/null <<SYSCTL
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL

sysctl --system >/dev/null

apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release conntrack >/dev/null

apt-get remove -y containerd 2>/dev/null || true

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | tee /etc/apt/keyrings/docker.asc >/dev/null
chmod a+r /etc/apt/keyrings/docker.asc

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" >/etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq containerd.io >/dev/null

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd >/dev/null

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet >/dev/null
REMOTE_EOF
}

init_control_plane() {
  log "Initializing control plane on ${CONTROL_PLANE}"
  run_remote "$CONTROL_PLANE" "sudo kubeadm init --apiserver-advertise-address=${CONTROL_PLANE} --control-plane-endpoint=${ENDPOINT}:6443 --upload-certs --pod-network-cidr=${POD_CIDR} --skip-phases=addon/kube-proxy --ignore-preflight-errors=NumCPU,Mem"
  run_remote "$CONTROL_PLANE" 'mkdir -p $HOME/.kube && sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config && sudo chown $(id -u):$(id -g) $HOME/.kube/config'
}

install_cilium() {
  log "Installing Cilium on ${CONTROL_PLANE}"
  run_remote "$CONTROL_PLANE" "curl -sL https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz | sudo tar xz -C /usr/local/bin"
  run_remote "$CONTROL_PLANE" "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash"
  run_remote "$CONTROL_PLANE" "helm repo add cilium https://helm.cilium.io/ && helm repo update"
  run_remote "$CONTROL_PLANE" "helm install cilium cilium/cilium --version ${CILIUM_VERSION} --namespace kube-system --create-namespace --set kubeProxyReplacement=true --set k8sServiceHost=${ENDPOINT} --set k8sServicePort=6443 --set bgpControlPlane.enabled=true --set ipam.mode=kubernetes --set gatewayAPI.enabled=true --set hubble.enabled=true --set hubble.relay.enabled=true --set hubble.ui.enabled=true"
}

configure_cilium() {
  log "Applying Cilium BGP and LB IPAM resources"

  run_remote "$CONTROL_PLANE" "cat > /tmp/cilium-networking.yaml" <<EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeeringPolicy
metadata:
  name: bgp-peering
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  virtualRouters:
    - localASN: ${CLUSTER_ASN}
      exportPodCIDR: true
      serviceAdvertisements:
        - LoadBalancerIP
      neighbors:
        - peerAddress: ${ROUTER_PEER}/32
          peerASN: ${ROUTER_ASN}
          peerPort: 179
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: lb-pool-public
spec:
  blocks:
    - cidr: ${LB_POOL_PUBLIC}
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: lb-pool-private
spec:
  blocks:
    - cidr: ${LB_POOL_PRIVATE}
EOF

  run_remote "$CONTROL_PLANE" "kubectl apply -f /tmp/cilium-networking.yaml"
}

join_control_planes() {
  local join_cmd
  local certificate_key

  join_cmd=$(run_remote "$CONTROL_PLANE" "sudo kubeadm token create --print-join-command")
  certificate_key=$(run_remote "$CONTROL_PLANE" "sudo kubeadm init phase upload-certs --upload-certs | awk '/^[0-9a-f]{64}\$/{key=\$0} END{print key}'")
  [[ -n "$certificate_key" ]] || fail "Failed to retrieve kubeadm certificate key"

  for node in "${CONTROL_PLANES[@]}"; do
    log "Joining control plane node ${node}"
    run_remote "$node" "sudo ${join_cmd} --control-plane --certificate-key ${certificate_key}"
  done
}

join_workers() {
  local join_cmd

  join_cmd=$(run_remote "$CONTROL_PLANE" "sudo kubeadm token create --print-join-command")

  for worker in "${WORKERS[@]}"; do
    log "Joining worker ${worker}"
    run_remote "$worker" "sudo ${join_cmd}"
  done
}

main() {
  prepare_node "$CONTROL_PLANE"
  for node in "${CONTROL_PLANES[@]}"; do
    prepare_node "$node"
  done
  for node in "${WORKERS[@]}"; do
    prepare_node "$node"
  done

  init_control_plane
  install_cilium

  if [[ -n "$ROUTER_PEER" ]]; then
    configure_cilium
  else
    warn "Skipping BGP and LB IPAM manifest generation because --router-peer was not provided"
  fi

  join_control_planes
  join_workers

  log "Cluster bootstrap complete"
  warn "Run 'kubectl get nodes -o wide' and 'kubectl -n kube-system exec ds/cilium -- cilium status --verbose' to validate the cluster"
}

main
