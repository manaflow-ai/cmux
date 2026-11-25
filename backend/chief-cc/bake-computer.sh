#!/usr/bin/env bash
# Bakes the Chief's computer image (CHIEF_CC_COMPUTER_SNAPSHOT; apps/api/src/chief-brain-cc/sandbox-computer-setup.ts):
# a Freestyle VM from BASE (freestyle/ubuntu-sm, the small Ubuntu every Chief sandbox starts from) plus the desktop
# `chief-vm computer setup` installs (TigerVNC's Xvnc on :1 with RFB on loopback only, the session and accessibility
# buses, openbox, Chrome, xdotool, ImageMagick and cua-driver pinned to the devbox's version), run once from the same
# SETUP script the Worker runs, then a snapshot named SLUG. A sandbox made with `chief-vm create --image computer`
# then sets up in seconds: SETUP finds everything installed. Nothing secret is left in the image. The bake VM is
# deleted.
#
#   FREESTYLE_KEY_FILE=~/.secrets/freestyle-...key backend/chief-cc/bake-computer.sh SLUG [BASE]
#
# Use the key of the account that holds the Chief's sandboxes (CHIEF_CC_FREESTYLE_API_KEY), then set
# CHIEF_CC_COMPUTER_SNAPSHOT on the Worker (wrangler.jsonc) to the printed snapshot id.
set -euo pipefail
slug="${1:?snapshot slug, e.g. cmuxnp-chiefcc-computer-v1}"
base="${2:-freestyle/ubuntu-sm}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api="${CLOUD_FREESTYLE_API_URL:-https://api.freestyle.sh}"
keyfile="${FREESTYLE_KEY_FILE:?FREESTYLE_KEY_FILE}"
command -v bun >/dev/null || { echo "bun is required (it prints the setup script from sandbox-computer-setup.ts)" >&2; exit 1; }
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
setup="$(mktemp)"
trap 'rm -f "$setup"' EXIT
CHIEF_SETUP_TS="$here/../apps/api/src/chief-brain-cc/sandbox-computer-setup.ts" bun -e 'process.stdout.write((await import(process.env.CHIEF_SETUP_TS)).SETUP)' > "$setup"
grep -q 'chief-desktop' "$setup" || { echo "the setup script did not print" >&2; exit 1; }
vm="$(call POST /v5/vms "$(jq -n --arg s "$base" '{snapshotId:$s, idleTimeoutSeconds:900, automaticRestart:false, ttlSeconds:3600, metadata:{purpose:"chief-cc-computer-bake"}, firewall:{rules:[{action:"allow", source:{}, destination:{public:true}}]}}')" | jq -r '.id // .vmId')"
[[ "$vm" == vm-* ]] || { echo "create failed" >&2; exit 1; }
trap 'rm -f "$setup"; call DELETE "/v5/vms/$vm" >/dev/null || true' EXIT
echo "bake vm $vm" >&2
exec_root 'bash -s' "$setup" | tail -3
# The image must not boot with this bake's desktop session: stop it (chief-desktop starts a fresh one on first use).
exec_root 'pkill -u chief || true; rm -rf /home/chief/.chief-desktop /home/chief/.chief-desktop.env /tmp/cua-install.log /root/.bash_history; cua-driver --version; command -v Xvnc; sync'
snap="$(call POST "/v5/vms/$vm/snapshot" "$(jq -n --arg n "$slug" '{slug:$n, displayName:$n}')")"
jq -c '{snapshotId: (.snapshotId // .id), name: (.name // .slug)}' <<<"$snap"
