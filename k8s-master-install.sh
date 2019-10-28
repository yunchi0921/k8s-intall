#!/bin/bash
set -e

nodes=( "10.240.0.36")
node_num=${#nodes[*]}
user="lemon830921"

echo "Installing prerequisites"
sudo apt-get update &&  \\
	sudo apt-get install \
	apt-transport-https \
        ca-certificates \
    	curl \
        gnupg2 \
	software-properties-common

echo "Add Docker's official GPG key"
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -

echo "Set up the docker stable repository"
sudo add-apt-repository \
	"deb [arch=amd64] https://download.docker.com/linux/debian \
	$(lsb_release -cs) \
	stable"

echo "Install Docker Engine - Community"
sudo apt-get update && sudo apt-get install docker-ce=18.06.2~ce~3-0~debian

sudo mkdir -p /etc/systemd/system/docker.service.d

echo "Restart docker" 
sudo systemctl daemon-reload
sudo systemctl restart docker

echo "Install apt-transport-https"
sudo apt-get update && sudo apt-get install -y apt-transport-https curl

echo "Add gpg kubernetes key"
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

echo "Add k8s kubernetes repository"
echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee  /etc/apt/sources.list.d/kubernetes.list

echo "Install kubectl kubelet kubeadm"
sudo apt update && \
       sudo apt install -y kubectl kubelet kubeadm	

echo "Set Pod network with flannel"
sudo kubeadm init --ignore-preflight-errors=NumCPU --pod-network-cidr=10.244.0.0/16

sudo sysctl net.bridge.bridge-nf-call-iptables=1

echo "Let kubeadm can be used as a regular user"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

token=$(sudo kubeadm token list | grep "kubeadm init" | awk '{print $1}')
token_ca_cert_hash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
master_ip=$(ip addr | grep 'state UP' -A2 | sed -n "3,3p"  | awk '{print $2}' | cut -f1 -d '/')

echo "Install flannel"
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

echo "Checking kubelet status..."
sudo systemctl status kubelet | grep "active (running)" &> /dev/null

if [ $? == 0 ]; then
	echo "OK"
else
	echo "Not ready"
fi

echo -n "Checking master node status..."

ready=false
while [ $ready == false ]
do
	if [ $(kubectl get node | grep master | awk '{print $2}') == "Ready" ]; then
		ready=true
		echo "OK"
	else
		echo -n "."
	fi
	sleep 1
done

echo "Creating worker installation script"
touch ./k8s-install-worker.sh
cat <<EOF | sudo tee ./k8s-install-worker.sh
sudo apt update && \
	sudo apt -y install \
	apt-transport-https \
	ca-certificates \
	curl \
	software-properties-common

echo "Add Docker's official GPG key"
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -

echo "Set up the docker stable repository"
sudo add-apt-repository \
	"deb [arch=amd64] https://download.docker.com/linux/debian \
	\$(lsb_release -cs) \
	stable"

echo "Add gpg kubernetes key"
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list

sudo swapoff -a

echo "Install docker-ce kubectl kubelet kubeadm"
sudo apt update && \
sudo apt install -y docker-ce=18.06.2~ce~3-0~debian  kubectl kubelet kubeadm kubernetes-cni
sudo kubeadm join $master_ip:6443 --token $token --discovery-token-ca-cert-hash sha256:$token_ca_cert_hash
EOF

if [ ! -d kube_log ]; then
	mkdir kube_log
fi

for (( i=0; i<node_num; i++))
do
	echo "Node: ${nodes[$i]} is joining cluser..."
	ssh $user@${nodes[$i]} 'bash -s' < ./k8s-install-worker.sh > kube_log/"${nodes[$i]}_$(date +'%Y-%m-%d_%H:%M:%S').log" 2>&1 &
done

times=1
while [ $times -le 21 ]
do
	for (( i=0; i<node_num; i++))
	do
		if [ "$(kubectl get nodes -o wide  | grep ${nodes[$i]} | awk '{print $2}')" == "Ready" ]; then
			echo "node ${nodes[$i]} Ready"
			del=${nodes[$i]}
			nodes=${nodes[@]/$del}
		else
			echo "waiting node ${nodes[$i]}"
		fi
	done
	times=$(( $times+1 ))
	if [ ${#node[*]} -eq 0 ]; then
		break
	fi
	sleep 5
done

echo "Done"

rm -rf k8s-install-worker.sh
