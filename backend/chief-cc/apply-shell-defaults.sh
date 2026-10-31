#!/usr/bin/env bash
# Retrofit the cloud VM shell defaults (web/services/vms/images/shell/shell-defaults.sh) onto a running VM,
# the same step bake.sh bakes into new snapshots. Idempotent; deletes nothing; SSH host keys and the tailnet
# name are left alone (tailscale runs with --hostname).
#
#   backend/chief-cc/apply-shell-defaults.sh ssh root@100.74.134.48
#   FREESTYLE_KEY_FILE=~/.secrets/freestyle-...key backend/chief-cc/apply-shell-defaults.sh freestyle vm-...
set -euo pipefail
mode="${1:?ssh|freestyle}"; target="${2:?target}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
images="$here/../../web/services/vms/images"
tarball="$(mktemp)"; trap 'rm -f "$tarball"' EXIT
tar --no-xattrs -C "$images" -czf "$tarball" shell/shell-defaults.sh shell/cmux-shell.sh shell/nvm-lazy.sh \
  devbox/cmux-terminfo.src devbox/cmux-terminfo.sh devbox/cmux-bashrc devbox/cmux-prompt.bash devbox/cmux-motd
remote='set -e; rm -rf /tmp/cmux-shell && mkdir -p /tmp/cmux-shell/in && base64 -d | tar -xz -C /tmp/cmux-shell/in && cp /tmp/cmux-shell/in/shell/* /tmp/cmux-shell/in/devbox/* /tmp/cmux-shell/ && bash /tmp/cmux-shell/shell-defaults.sh /tmp/cmux-shell && rm -rf /tmp/cmux-shell && infocmp -x xterm-ghostty >/dev/null && echo "hostname=$(hostname)"'
case "$mode" in
  ssh) base64 < "$tarball" | ssh -o BatchMode=yes "$target" "$remote" ;;
  freestyle)
    keyfile="${FREESTYLE_KEY_FILE:?FREESTYLE_KEY_FILE}"
    api="${CLOUD_FREESTYLE_API_URL:-https://api.freestyle.sh}"
    body="$(jq -n --arg c "$remote" --arg s "$(base64 < "$tarball" | tr -d '\n' | base64 | tr -d '\n')" '{command:$c, stdin:$s, timeoutMs:300000, linuxUser:"root"}')"
    out="$(curl -sS -m 600 -K <(printf 'header = "authorization: Bearer %s"\n' "$(cat "$keyfile")") -H 'content-type: application/json' -X POST "$api/v5/vms/$target/exec-await" --data-binary "$body")"
    jq -r '.stdout, .stderr' <<<"$out"
    [[ "$(jq -r '.statusCode' <<<"$out")" == 0 ]] ;;
  *) echo "mode must be ssh or freestyle" >&2; exit 2 ;;
esac
