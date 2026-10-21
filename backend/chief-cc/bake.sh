#!/usr/bin/env bash
# Bakes the Cloud Chief VM snapshot (chief-brain-cc/; backend/chief-cc/bake.sh): a Freestyle VM from BASE (a hand
# snapshot with Claude Code and node), plus tailscale, the `chief` and `ccproxy` users, run.mjs,
# start.sh, boot.sh, proxy.mjs and its unit, then a snapshot named SLUG. The tailscale state is
# empty in the snapshot (each VM joins with its own one-use key at boot.sh). The bake VM is deleted.
#
#   FREESTYLE_KEY_FILE=~/.secrets/freestyle-...key backend/chief-cc/bake.sh SLUG [BASE] [UPSTREAM]
set -euo pipefail
slug="${1:?snapshot slug, e.g. cmuxnp-chiefcc-v1}"
base="${2:-sh-8d6654a2debb485da9d58da06291e7bd}" # cmuxnp-stg-hand-v4: claude 2.1.302, node 24
upstream="${3:-http://100.120.48.119:4016}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api="${CLOUD_FREESTYLE_API_URL:-https://api.freestyle.sh}"
keyfile="${FREESTYLE_KEY_FILE:?FREESTYLE_KEY_FILE}"
auth() { printf 'header = "authorization: Bearer %s"\n' "$(cat "$keyfile")"; }
call() { curl -sS -m 600 -K <(auth) -H 'content-type: application/json' -X "$1" "$api$2" ${3:+--data-binary "$3"}; }
exec_root() { # exec_root COMMAND [STDIN_FILE]
  local body
  if [[ -n "${2:-}" ]]; then body="$(jq -n --arg c "$1" --arg s "$(base64 < "$2" | tr -d '\n')" '{command:$c, stdin:$s, timeoutMs:300000, linuxUser:"root"}')"
  else body="$(jq -n --arg c "$1" '{command:$c, timeoutMs:300000, linuxUser:"root"}')"; fi
  local out; out="$(call POST "/v5/vms/$vm/exec-await" "$body")"
  local code; code="$(jq -r '.statusCode' <<<"$out")"
  [[ "$code" == "0" ]] || { jq -r '.stdout, .stderr' <<<"$out" | tail -20 >&2; echo "exec failed ($code): $1" >&2; exit 1; }
  jq -r '.stdout' <<<"$out"
}
vm="$(call POST /v5/vms "$(jq -n --arg s "$base" '{snapshotId:$s, idleTimeoutSeconds:900, automaticRestart:false, ttlSeconds:3600, metadata:{purpose:"chief-cc-bake"}, firewall:{rules:[{action:"allow", source:{}, destination:{public:true}}]}}')" | jq -r '.id // .vmId')"
[[ "$vm" == vm-* ]] || { echo "create failed" >&2; exit 1; }
trap 'call DELETE "/v5/vms/$vm" >/dev/null || true' EXIT
echo "bake vm $vm" >&2
exec_root 'command -v tailscale >/dev/null || (curl -fsSL https://tailscale.com/install.sh | sh) >/tmp/ts.log 2>&1; tailscale version | head -1'
exec_root 'id chief >/dev/null 2>&1 || useradd -m -s /bin/bash chief; id ccproxy >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin ccproxy; install -d -o chief -g chief -m 755 /home/chief/work; install -d -m 755 /opt/chief-cc /etc/chief-cc'
for f in run.mjs proxy.mjs; do exec_root "cat > /opt/chief-cc/$f && chmod 644 /opt/chief-cc/$f" "$here/image/$f"; done
for f in start.sh boot.sh; do exec_root "cat > /opt/chief-cc/$f && chmod 755 /opt/chief-cc/$f" "$here/image/$f"; done
printf '%s\n' "$upstream" > /tmp/chief-cc-upstream.$$
exec_root 'cat > /etc/chief-cc/upstream && chmod 644 /etc/chief-cc/upstream' /tmp/chief-cc-upstream.$$
rm -f /tmp/chief-cc-upstream.$$
cat > /tmp/chief-cc-unit.$$ <<'UNIT'
[Unit]
Description=Cloud Chief model forward (POST /v1/messages to the sr2 gateway only)
[Service]
User=ccproxy
ExecStart=/opt/node/bin/node /opt/chief-cc/proxy.mjs
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
exec_root 'cat > /etc/systemd/system/chief-cc-proxy.service && systemctl daemon-reload' /tmp/chief-cc-unit.$$
rm -f /tmp/chief-cc-unit.$$
# Claude Code's first run state for the agent user (no onboarding prompt in -p mode), then a clean tailnet state.
exec_root 'runuser -u chief -- /usr/local/bin/claude --version; systemctl stop chief-cc-proxy 2>/dev/null || true; tailscale logout 2>/dev/null || true; systemctl stop tailscaled; systemctl disable tailscaled >/dev/null 2>&1 || true; rm -rf /var/lib/tailscale/*; rm -f /root/.bash_history /tmp/ts.log; sync'
snap="$(call POST "/v5/vms/$vm/snapshot" "$(jq -n --arg n "$slug" '{slug:$n, displayName:$n}')")"
jq -c '{snapshotId: (.snapshotId // .id), name: (.name // .slug)}' <<<"$snap"
