#!/usr/bin/env bash
# Proves the Cloud Chief turn machine's network settings (apps/api/src/chief-brain-cc/net.ts) on a real
# Freestyle VM from SNAPSHOT: it closes the agent user as boot.sh does, applies each setting's script as
# root (as turn.ts does), and checks what the agent user `chief` reaches. With --old it only checks the
# boot.sh block (the agent reaches nothing). The VM is deleted at the end.
#
#   FREESTYLE_KEY_FILE=~/.secrets/freestyle-...key backend/chief-cc/net-check.sh SNAPSHOT [--old]
set -euo pipefail
snap="${1:?snapshot id}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api="${CLOUD_FREESTYLE_API_URL:-https://api.freestyle.sh}"
keyfile="${FREESTYLE_KEY_FILE:?FREESTYLE_KEY_FILE}"
auth() { printf 'header = "authorization: Bearer %s"\n' "$(cat "$keyfile")"; }
call() { curl -sS -m 300 -K <(auth) -H 'content-type: application/json' -X "$1" "$api$2" ${3:+--data-binary "$3"}; }
run() { # run COMMAND [STDIN_FILE] -> exit code, output on stdout
  local body
  if [[ -n "${2:-}" ]]; then body="$(jq -n --arg c "$1" --arg s "$(base64 < "$2" | tr -d '\n')" '{command:$c, stdin:$s, timeoutMs:60000, linuxUser:"root"}')"
  else body="$(jq -n --arg c "$1" '{command:$c, timeoutMs:60000, linuxUser:"root"}')"; fi
  local out; out="$(call POST "/v5/vms/$vm/exec-await" "$body")"
  jq -r '.stdout, .stderr' <<<"$out" | sed '/^$/d;/^null$/d' | tail -5 >&2
  return "$(jq -r '.statusCode // 1' <<<"$out")"
}
fails=0
expect() { # expect yes|no WHAT COMMAND (run as the agent user)
  local got=no
  run "runuser -u chief -- bash -c $(printf '%q' "$3")" && got=yes
  if [[ "$got" == "$1" ]]; then echo "ok    $2: $got"; else echo "FAIL  $2: $got, want $1"; fails=$((fails + 1)); fi
}
script() { (cd "$here/../apps/api" && bun -e "import { CC_NET_DEFAULT, netScript } from './src/chief-brain-cc/net.ts'; process.stdout.write(netScript({ ...CC_NET_DEFAULT, ...JSON.parse(process.argv[1]) }))" "$1") > "$tmp/net.sh"; }

tmp="$(mktemp -d)"
vm="$(call POST /v5/vms "$(jq -n --arg s "$snap" '{snapshotId:$s, idleTimeoutSeconds:600, automaticRestart:false, ttlSeconds:1800, metadata:{purpose:"chief-cc-net-check"}, firewall:{rules:[{action:"allow", source:{}, destination:{public:true}}]}}')" | jq -r '.id // .vmId')"
[[ "$vm" == vm-* ]] || { echo "create failed" >&2; exit 1; }
trap 'call DELETE "/v5/vms/$vm" >/dev/null || true; rm -rf "$tmp"' EXIT
echo "vm $vm ($(call GET "/v5/vms/$vm" | jq -r '.ipMode'))"
# boot.sh's block, without the tailnet join (no key here).
run 'systemctl mask --now systemd-resolved.service >/dev/null 2>&1 || true; install -d -m 700 /run/chief; uid="$(id -u chief)"; nft add table inet chiefcc; nft add chain inet chiefcc out "{ type filter hook output priority 0; }"; nft add rule inet chiefcc out meta skuid "$uid" oif lo ip daddr 127.0.0.1 tcp dport 4017 accept; nft add rule inet chiefcc out meta skuid "$uid" counter reject'
GH='timeout 20 git ls-remote https://github.com/manaflow-ai/cmux HEAD'
if [[ "${2:-}" == "--old" ]]; then
  echo "== boot.sh only"
  expect no "dns github.com" 'getent hosts github.com'
  expect no "git ls-remote github" "$GH"
  expect no "github by address" 'timeout 10 curl -sS -o /dev/null --resolve github.com:443:140.82.112.3 https://github.com'
  exit "$fails"
fi

echo "== default (Internet over IPv4 and IPv6, DNS)"
script '{}'; run "bash -s" "$tmp/net.sh"
expect yes "dns github.com" 'getent hosts github.com'
expect yes "git ls-remote github" "$GH"
expect yes "IPv4 out" 'timeout 10 curl -4 -sSf -o /dev/null https://api.ipify.org'
expect yes "IPv6 out" 'timeout 10 curl -6 -sSf -o /dev/null https://api6.ipify.org'
expect yes "tailscale control plane" 'timeout 10 curl -sS -o /dev/null https://controlplane.tailscale.com/key?v=71'
expect yes "npm registry" 'timeout 10 curl -sSf -o /dev/null https://registry.npmjs.org/'
expect no "link-local metadata address" 'timeout 5 curl -sS -o /dev/null http://169.254.169.254/'
expect no "loopback ssh" 'timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/22"'
expect no "tailnet address" 'timeout 5 bash -c "exec 3<>/dev/tcp/100.100.100.100/53"'

echo "== internet off, allow github.com"
script '{"internet":false,"allow":["github.com"]}'; run "bash -s" "$tmp/net.sh"
expect yes "git ls-remote github" "$GH"
expect no "npm registry" 'timeout 10 curl -sS -o /dev/null https://registry.npmjs.org/'

echo "== dns off, deny 1.1.1.1"
script '{"dns":false,"deny":["1.1.1.1"]}'; run "bash -s" "$tmp/net.sh"
expect no "dns github.com" 'getent hosts github.com'
expect no "denied 1.1.1.1" 'timeout 5 curl -sS -o /dev/null https://1.1.1.1/'
expect yes "github by address" 'timeout 10 curl -sS -o /dev/null --resolve github.com:443:140.82.112.3 https://github.com'

echo "== local and tailnet on"
script '{"local":true,"tailnet":true}'; run "bash -s" "$tmp/net.sh"
expect yes "loopback ssh" 'timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/22"'
echo "failures: $fails"
exit "$fails"
