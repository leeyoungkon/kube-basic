
#!/bin/bash
set -euo pipefail
umask 077

API_SERVER="https://192.168.1.89:6443"
CA_CRT="/etc/kubernetes/pki/ca.crt"
CA_KEY="/etc/kubernetes/pki/ca.key"
ADMIN_CONF="/etc/kubernetes/admin.conf"
WORK="/root/student-k8s"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo"
    exit 1
fi

for f in "$CA_CRT" "$CA_KEY" "$ADMIN_CONF"; do
    if [ ! -f "$f" ]; then
        echo "Missing file: $f"
        exit 1
    fi
done

mkdir -p "$WORK"
chmod 700 "$WORK"

export KUBECONFIG="$ADMIN_CONF"

cat > "$WORK/client.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF

for i in $(seq -w 1 12); do

    USER="stud$i"
    NS="$USER"
    DIR="$WORK/$USER"

    echo "============================"
    echo "Setting up $USER"
    echo "============================"

    # Linux 계정 확인
    if ! id "$USER" >/dev/null 2>&1; then
        echo "ERROR: $USER does not exist"
        exit 1
    fi

    HOME_DIR=$(getent passwd "$USER" | cut -d: -f6)
    GROUP=$(id -gn "$USER")

    # 기존 인증서 덮어쓰기 방지
    if [ -e "$DIR" ]; then
        echo "ERROR: $DIR already exists"
        echo "Existing credentials will not be overwritten"
        exit 1
    fi

    mkdir -m 700 "$DIR"

    # 1. 학생별 개인키 생성
    openssl genpkey -algorithm RSA \
        -pkeyopt rsa_keygen_bits:3072 \
        -out "$DIR/$USER.key"

    # 2. 인증서 서명 요청(CSR)
    openssl req -new \
        -key "$DIR/$USER.key" \
        -out "$DIR/$USER.csr" \
        -subj "/CN=$USER"

    # 3. Kubernetes CA로 클라이언트 인증서 발급
    openssl x509 -req \
        -in "$DIR/$USER.csr" \
        -CA "$CA_CRT" \
        -CAkey "$CA_KEY" \
        -set_serial "0x$(openssl rand -hex 16)" \
        -out "$DIR/$USER.crt" \
        -days 30 \
        -sha256 \
        -extfile "$WORK/client.ext"

    # 4. 개인 kubeconfig 생성
    KC="$DIR/config"

    kubectl --kubeconfig="$KC" config set-cluster kubernetes \
        --server="$API_SERVER" \
        --certificate-authority="$CA_CRT" \
        --embed-certs=true

    kubectl --kubeconfig="$KC" config set-credentials "$USER" \
        --client-certificate="$DIR/$USER.crt" \
        --client-key="$DIR/$USER.key" \
        --embed-certs=true

    kubectl --kubeconfig="$KC" config set-context "$USER" \
        --cluster=kubernetes \
        --user="$USER" \
        --namespace="$NS"

    kubectl --kubeconfig="$KC" config use-context "$USER"

    # 5. 전용 Namespace 생성
    kubectl create namespace "$NS" \
        --dry-run=client -o yaml | kubectl apply -f -

    # 기본 Pod 보안 정책
    kubectl label namespace "$NS" \
        pod-security.kubernetes.io/enforce=baseline \
        --overwrite

    # 6. Namespace 전용 Role 생성
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: student-role
  namespace: $NS
rules:
- apiGroups: [""]
  resources:
    - pods
    - pods/log
    - services
    - configmaps
    - persistentvolumeclaims
  verbs:
    - get
    - list
    - watch
    - create
    - update
    - patch
    - delete
- apiGroups: ["apps"]
  resources:
    - deployments
    - replicasets
    - statefulsets
  verbs:
    - get
    - list
    - watch
    - create
    - update
    - patch
    - delete
EOF

    # 7. 사용자와 Role 연결
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: student-binding
  namespace: $NS
subjects:
- kind: User
  name: $USER
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: student-role
  apiGroup: rbac.authorization.k8s.io
EOF

    # 8. 학생 홈에 kubeconfig 설치
    install -d -m 700 \
        -o "$USER" -g "$GROUP" \
        "$HOME_DIR/.kube"

    install -m 600 \
        -o "$USER" -g "$GROUP" \
        "$KC" "$HOME_DIR/.kube/config"

    echo "$USER completed"
done

echo "================================"
echo "All student kubeconfigs created"
echo "================================"
