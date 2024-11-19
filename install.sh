#!/bin/bash

WORKING_DIR="$(pwd)"

print_subheader() {
    echo -e "\e[1;36m--- $1 ---\e[0m"
}

print_header() {
    echo -e "\n\e[1;34m############################### $1 ###############################\e[0m"
}

print_success() {
    echo -e "\e[1;32m$1\e[0m"
}

print_error() {
    echo -e "\e[1;31mERROR: $1\e[0m"
}

print_info() {
    echo -e "\e[1;33mINFO: $1\e[0m"
}



check-root(){
  if [[ $EUID -eq 0 ]]; then
  echo "This script must NOT be run as root" 1>&2
  exit 1
  fi
}

timer-sec(){
  secs=$((${1}))
  while [ $secs -gt 0 ]; do
    echo -ne "Waiting for $secs\033[0K seconds ...\r"
    sleep 1
    : $((secs--))
  done
}

install-packages() {
  sudo apt-get update
  sudo apt-get install -y vim tmux git curl iproute2 iputils-ping iperf3 tcpdump python3-pip jq
  sudo pip3 install virtualenv
}

# Disable Swap
disable-swap() {
    print_info "Disabling swap ..."
    if [ -n "$(swapon -s)" ]; then
        # Swap is enabled, disable it
        sudo swapoff -a

        # Comment out the swap entry in /etc/fstab to disable it permanently
        sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

        echo "Swap has been disabled and commented out in /etc/fstab."
    else
        echo "Swap is not enabled on this system."
    fi
}

disable-firewall() {
  print_info "Disabling firewall ..."
  sudo ufw disable
}

# Install containerd as Kubernetes CRI
# Based on https://docs.docker.com/engine/install/ubuntu/
# Fixme: If containerd is not running with proper settings, it just checks if containerd is there and exits.
install-containerd() {
  if [ -x "$(command -v containerd)" ]
  then
          print_info "Containerd is already installed."
  else
          echo "Installing containerd ..."
          # Add Docker's official GPG key:
          sudo apt-get update
          sudo apt-get install -y ca-certificates curl gnupg wget apt-transport-https -y
          sudo install -m 0755 -d /etc/apt/keyrings
          sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
          sudo chmod a+r /etc/apt/keyrings/docker.asc

          # Add the repository to Apt sources:
          echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

          sudo apt-get update
          sudo apt-get install containerd.io
          containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
          sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
          sudo systemctl enable containerd
          sudo systemctl restart containerd
  fi

  # Check if Containerd is running
  if sudo systemctl is-active containerd &> /dev/null; then
    print_success "Containerd is running :)"
  else
    print_error "Containerd installation failed or is not running!"
  fi
}

# Setup K8s Networking
# Based on https://kubernetes.io/docs/setup/production-environment/container-runtimes/#forwarding-ipv4-and-letting-iptables-see-bridged-traffic
setup-k8s-networking() {
  echo "Setting up Kubernetes networking ..."
  # Load required kernel modules
  cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

  sudo modprobe overlay
  sudo modprobe br_netfilter

  # Configure sysctl parameters for Kubernetes
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

  # Apply sysctl parameters without reboot
  sudo sysctl --system > /dev/null

}

# Install Kubernetes
install-k8s() {
  if [ -x "$(command -v kubectl)" ] && [ -x "$(command -v kubeadm)" ] && [ -x "$(command -v kubelet)" ]; then
    print_info "Kubernetes components (kubectl, kubeadm, kubelet) are already installed."
  else
    print_info "Installing Kubernetes components (kubectl, kubeadm, kubelet) ..."
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gpg
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    sudo systemctl enable --now kubelet
  fi
}

create-k8s-cluster() {
  if [ -f "/etc/kubernetes/admin.conf" ]; then
    print_info "A Kubernetes cluster already exists. Skipping cluster creation."
  else
    print_info "Creating k8s cluster ..."
    
    # Run kubeadm init and check if it succeeds
    if sudo kubeadm init --config kubeadm-config.yaml; then
      # Setup kubectl without sudo
      mkdir -p ${HOME}/.kube
      sudo cp /etc/kubernetes/admin.conf ${HOME}/.kube/config
      sudo chown $(id -u):$(id -g) ${HOME}/.kube/config

      # Wait for cluster readiness
      timer=10
      print_info "Waiting $timer secs for cluster to be ready"
      timer-sec $timer

      # Remove NoSchedule taint from all nodes
      echo "Allowing scheduling pods on master node ..."
      kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
    else
      print_error "Failed to initialize Kubernetes cluster. Please check the logs for errors."
      exit
    fi
  fi
}

# Install Calico as CNI
install-cni() {
  if kubectl get pods -n kube-system -l app=calico | grep -q '1/1'; then
    print_info "Calico is already running. Skipping installation."
  else
    print_info "Installing Calico as primary CNI ..."
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml
    timer-sec 10
    kubectl wait pods -n kube-system -l app=calico --for condition=Ready --timeout=120s
  fi
}

# Install Multus as meta CNI
install-multus() {
  if kubectl get pods -n kube-system -l app=multus | grep -q '1/1'; then
    print_info "Multus is already running. Skipping installation."
  else
    print_info "Installing Multus as meta CNI ..."
    git -C build/multus-cni pull || git clone https://github.com/k8snetworkplumbingwg/multus-cni.git build/multus-cni
    cd build/multus-cni
    cat ./deployments/multus-daemonset.yml | kubectl apply -f -
    timer-sec 10
    kubectl wait pods -n kube-system  -l app=multus --for condition=Ready --timeout=120s
    cd $WORKING_DIR
  fi
}


# Install Helm3
install-helm() {
  HELM_VERSION=$(helm version --short 2> /dev/null)

  if [[ "$HELM_VERSION" != *"v3"* ]]; then
    print_info "Helm 3 is not installed. Proceeding to install Helm ..."

    # Install Helm prerequisites
    sudo apt-get install apt-transport-https wget --yes
    wget https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz

    tar -zxvf helm-v3.16.3-linux-amd64.tar.gz
    sudo mv linux-amd64/helm /usr/local/bin/helm
  else
    print_info "Helm 3 is already installed."
  fi
}

install-openebs() {
  if kubectl get pods -n openebs -l app=openebs | grep -q '1/1'; then
    print_info "OpenEBS is already running. Skipping installation."
  else
    print_info "Installing OpenEBS for storage management ..."
    helm repo add openebs https://openebs.github.io/charts
    helm repo update
    helm upgrade --install openebs --namespace openebs openebs/openebs --create-namespace

    # patch k8s storageclass to make openebs-hostpath as default
    kubectl patch storageclass openebs-hostpath -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  fi
}

setup-ovs-cni() {
  if [ -x "$(command -v ovs-vsctl)" ]; then
    print_info "OpenVSwitch is already installed."
  else
    print_info "Installing OpenVSwitch ..."
    sudo apt-get update
    sudo apt-get install -y openvswitch-switch
  fi

  print_info "Configuring bridges for use by ovs-cni ..."
  sudo ovs-vsctl --may-exist add-br n2br
  sudo ovs-vsctl --may-exist add-br n3br
  sudo ovs-vsctl --may-exist add-br n4br

  # install ovs-cni
  # install cluster-network-addons operator
  print_info "Installing ovs-cni ..."

  kubectl apply -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.96.0/namespace.yaml
  kubectl apply -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.96.0/network-addons-config.crd.yaml
  kubectl apply -f https://github.com/kubevirt/cluster-network-addons-operator/releases/download/v0.96.0/operator.yaml

  kubectl apply -f https://gist.githubusercontent.com/niloysh/1f14c473ebc08a18c4b520a868042026/raw/d96f07e241bb18d2f3863423a375510a395be253/network-addons-config.yaml
  timer-sec 10
  kubectl wait networkaddonsconfig cluster --for condition=Available

}

setup-ovs-bridges() {
  if [ -x "$(command -v ovs-vsctl)" ]; then
    print_info "OpenVSwitch is already installed."
  else
    print_info "Installing OpenVSwitch ..."
    sudo apt-get update
    sudo apt-get install -y openvswitch-switch
  fi

  print_info "Configuring bridges for use by ovs-cni ..."
  sudo ovs-vsctl --may-exist add-br n2br
  sudo ovs-vsctl --may-exist add-br n3br
  sudo ovs-vsctl --may-exist add-br n4br
}

show-join-command-info() {
  print_info "Worker node configured ..."
  print_info "Run worker-join-token.sh on the master node, and run the output (with sudo) on each worker node"
}

check-root  # script should NOT be run as ROOT

# Check for --worker flag
if [[ "$1" == "--worker" ]]; then
    print_header "Setting up node as Kubernetes worker node"
    install-packages
    disable-swap
    disable-firewall
    setup-k8s-networking
    install-containerd
    install-k8s
    setup-ovs-bridges
    show-join-command-info
else
    
    print_header "Set up node as Kubernetes master node"

    print_header "Prepare node for Kubernetes Install (Automator Deployment [1/6])"

    print_subheader "Install system packages"
    install-packages
    print_success "System packages installed."

    print_subheader "Setup Kubernetes configurations for networking"
    disable-swap
    disable-firewall
    setup-k8s-networking
    print_success "Kubernetes configuraitons for networking done."

    print_header "Install Container Runtime (Automator Deployment [2/6])"
    print_subheader "Install containerd as Container Runtime"
    install-containerd
    print_success "Container Runtime installed."

    print_header "Install Kubernetes and create cluster (Automator Deployment [3/6])"
    print_subheader "Install Kubernetes"
    install-k8s
    print_success "Kubernetes installed."
    print_subheader "Create single-node Kubernetes cluster"
    create-k8s-cluster
    print_success "Kubernetes cluster created."

    print_header "Install Multus and CNI for 5G networking (Automator Deployment [4/6])"
    print_subheader "Install Flannel as primary CNI"
    install-cni
    print_success "Flannel installed."

    print_subheader "Install Multus as meta CNI"
    install-multus
    print_success "Multus installed."

    
    print_subheader "Install OVS-CNI as secondary CNI"
    setup-ovs-cni
    print_success "OVS-CNI installed."

    print_header "Setup Storage for Kubernetes using OpenEBS (Automator Deployment [5/6])"
    print_subheader "Install Helm package manager for Kubernetes"
    install-helm
    print_success "Helm installed."
    print_subheader "Install OpenEBS"
    install-openebs
    print_success "OpenEBS installed"
    
fi

print_header "Running post installation scripts (Automator Deployment [6/6])"

print_subheader "Enable running kubectl without sudo"
SCRIPT_DIRECTORY="$(dirname $(realpath "$0"))"
source $SCRIPT_DIRECTORY/run-kubectl-without-sudo.sh

print_subheader "Increase fsnotify limits for kubectl logs"
./increase-fsnotify-limits.sh
