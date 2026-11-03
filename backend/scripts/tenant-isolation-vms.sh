#!/usr/bin/env bash
# Tenant isolation at the VM layer (plans/cmux-next/tenant-isolation-DESIGN.md section 5.8), on two SMALL real Freestyle VMs made
# from the image an end user's session runs on (default: the staging chief-cc snapshot). Tenant A's VM and tenant B's VM are different
# "accounts"; the script plants a canary file in B and checks, from A as root, that B is unreachable, that the two clones carry
# different identities, that a fresh VM holds no credential, and that the Freestyle control plane is unreachable without a key.
# Both VMs get ttlSeconds 1800 and are deleted on exit. Prints ok/FAIL lines and exits with the number of failures.
#
#   FREESTYLE_KEY_FILE=~/.secrets/freestyle-cmux-next-staging-....key backend/scripts/tenant-isolation-vms.sh [SNAPSHOT]
set -euo pipefail
snap="${1:-sh-e4d3df6380b547e4b59b9d59b6439911}"
api="${CLOUD_FREESTYLE_API_URL:-https://api.freestyle.sh}"
keyfile="${FREESTYLE_KEY_FILE:?FREESTYLE_KEY_FILE}"
key="$(grep -v '^#' "$keyfile" | head -1 | sed 's/^[A-Za-z_]*=//; s/"//g')"
auth() { printf 'header = "authorization: Bearer %s"\n' "$key"; }
call() { curl -sS -m 300 -K <(auth) -H 'content-type: application/json' -X "$1" "$api$2" ${3:+--data-binary "$3"}; }
fails=0
run() { # run VM COMMAND -> stdout of the command; exit status of the command is in $RC
  local out; out="$(call POST "/v5/vms/$1/exec-await" "$(jq -n --arg c "$2" '{command:$c, timeoutMs:90000, linuxUser:"root"}')")"
  RC="$(jq -r '.statusCode // 1' <<<"$out")"
  jq -r '.stdout // ""' <<<"$out"
}
check() { # check yes|no WHAT -> compares $2 with the wanted answer
  if [[ "$1" == "$3" ]]; then echo "ok    $2: $3"; else echo "FAIL  $2: got $3, want $1"; fails=$((fails + 1)); fi
}
vms=()
cleanup() { for v in "${vms[@]:-}"; do [[ -n "$v" ]] && call DELETE "/v5/vms/$v" >/dev/null || true; done; }
trap cleanup EXIT
make() {
  local id; id="$(call POST /v5/vms "$(jq -n --arg s "$snap" --arg t "$1" '{snapshotId:$s, idleTimeoutSeconds:600, automaticRestart:false, ttlSeconds:1800, metadata:{purpose:"tenant-isolation", tenant:$t}, firewall:{rules:[{action:"allow", source:{}, destination:{public:true}}]}}')" | jq -r '.id // .vmId')"
  [[ "$id" == vm-* ]] || { echo "create $1 failed" >&2; exit 99; }
  vms+=("$id"); echo "$id"
}
A="$(make a)"; B="$(make b)"
echo "tenant A vm $A, tenant B vm $B (snapshot $snap)"
infoB="$(call GET "/v5/vms/$B")"
v6B="$(jq -r '.publicIpv6 // empty' <<<"$infoB")"; v4B="$(jq -r '.egressIpv4 // empty' <<<"$infoB")"
echo "B addresses: ipv6=${v6B:-none} egress-ipv4=${v4B:-none}"

# 1. Identity: two clones of one image must not share machine-id, SSH host keys or the kernel random state.
ida="$(run "$A" 'cat /etc/machine-id; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | cut -d" " -f2; cat /proc/sys/kernel/random/boot_id' | tr '\n' ' ')"
idb="$(run "$B" 'cat /etc/machine-id; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | cut -d" " -f2; cat /proc/sys/kernel/random/boot_id' | tr '\n' ' ')"
mida="$(awk '{print $1}' <<<"$ida")"; midb="$(awk '{print $1}' <<<"$idb")"
check yes "machine-id differs between the two clones" "$([[ -n "$mida" && "$mida" != "$midb" ]] && echo yes || echo no)"
ka="$(awk '{print $2}' <<<"$ida")"; kb="$(awk '{print $2}' <<<"$idb")"
check yes "SSH host key differs between the two clones" "$([[ -n "$ka" && "$ka" != "$kb" ]] && echo yes || echo no)"

# 2. Residue: a fresh VM from the image holds no credential, token or private key of anyone (SSH host keys are the VM's own).
resid="$(run "$A" 'grep -rIlE "sk-ant-|ghp_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|xox[bp]-|tskey-(auth|api)-|cmuxvm_sk_|eyJhbGciOi[A-Za-z0-9._-]{40}" /root /home /etc /opt /srv /usr/local /var/lib /var/log 2>/dev/null | grep -v "^/var/lib/dpkg\|^/var/lib/apt\|^/usr/local/lib/node_modules\|/node_modules/" | head -20')"
privk="$(run "$A" 'grep -rIl -- "-----BEGIN [A-Z ]*PRIVATE KEY-----" /root /home /opt /srv /usr/local /var/lib 2>/dev/null | grep -v "/node_modules/\|^/var/lib/dpkg\|^/usr/local/lib/node_modules" | head -20')"
echo "${resid:+residue files: $resid}"; echo "${privk:+private key files: $privk}"
check no "credential strings in the image" "$([[ -n "$resid" ]] && echo yes || echo no)"
check no "private keys outside SSH host keys and node_modules" "$([[ -n "$privk" ]] && echo yes || echo no)"
envs="$(run "$A" 'for p in /proc/[0-9]*; do tr "\0" "\n" < $p/environ 2>/dev/null; done | grep -E "^(FREESTYLE|CLOUDFLARE|ANTHROPIC|OPENAI|AWS|GITHUB|TS_AUTHKEY|TAILSCALE)[A-Z_]*=" | cut -d= -f1 | sort -u | tr "\n" " "')"
check no "provider secrets in any process environment (${envs:-none})" "$([[ -n "$envs" ]] && echo yes || echo no)"
bindleft="$(run "$A" 'test -e /var/lib/cmux/bind.json && echo present || echo absent')"
check absent "an unconsumed bind token file on a fresh VM" "${bindleft:-absent}"

# 3. Cross-VM network reach. B listens on every interface; A (root) dials B's public addresses. Control: A dials its OWN listener.
listener='import socket,threading,time
def serve(port):
    for fam,addr in ((socket.AF_INET6,"::"),(socket.AF_INET,"0.0.0.0")):
        try:
            s=socket.socket(fam,socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((addr,port)); s.listen(8)
            threading.Thread(target=lambda s=s:[ (c:=s.accept()[0]).sendall(b"CANARY-B-OPEN\n") or c.close() for _ in iter(int,1)],daemon=True).start()
        except OSError: pass
for p in (8080,7420,1337,3000,5432): serve(p)
time.sleep(240)'
run "$B" "echo CANARY-B-FILE > /root/CANARY-B; nohup python3 -c '$listener' >/tmp/l.log 2>&1 </dev/null & sleep 2; ss -ltn | grep -c LISTEN" >/dev/null
run "$A" "nohup python3 -c '$listener' >/tmp/l.log 2>&1 </dev/null & sleep 2; echo started" >/dev/null
probe='import socket,sys
host,port,fam=sys.argv[1],int(sys.argv[2]),socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
s=socket.socket(fam,socket.SOCK_STREAM); s.settimeout(6)
try:
    s.connect((host,port)); print(s.recv(32).decode().strip())
except Exception as e: print("closed:",type(e).__name__)'
for port in 8080 7420 1337 3000 5432 22; do
  if [[ -n "$v6B" ]]; then r="$(run "$A" "python3 -c '$probe' $v6B $port")"; check no "A reaches B public IPv6 port $port ($r)" "$([[ "$r" == *CANARY-B-OPEN* ]] && echo yes || echo no)"; fi
  if [[ -n "$v4B" ]]; then r="$(run "$A" "python3 -c '$probe' $v4B $port")"; check no "A reaches B egress IPv4 port $port ($r)" "$([[ "$r" == *CANARY-B-OPEN* ]] && echo yes || echo no)"; fi
done
# Positive control: the probe works. A dials its own listener on loopback.
r="$(run "$A" "python3 -c '$probe' 127.0.0.1 7420")"; check yes "control: A reaches its own listener, so a closed result above means closed ($r)" "$([[ "$r" == *CANARY-B-OPEN* ]] && echo yes || echo no)"

# 4. Control plane: no Freestyle key is reachable from inside, and the API refuses the VM without one.
code="$(run "$A" 'curl -sS -m 10 -o /dev/null -w "%{http_code}" https://api.freestyle.sh/v5/vms')"
check yes "Freestyle API answers 401/403 to a VM with no key ($code)" "$([[ "$code" == 401 || "$code" == 403 ]] && echo yes || echo no)"
mdata="$(run "$A" 'curl -sS -m 5 -o /dev/null -w "%{http_code}" http://169.254.169.254/ || true')"
check no "link-local metadata endpoint answers ($mdata)" "$([[ "$mdata" == 2* ]] && echo yes || echo no)"
echo "failures: $fails"
exit "$fails"
