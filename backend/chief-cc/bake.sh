#!/usr/bin/env bash
# Bakes the Cloud Chief VM snapshot (chief-brain-cc/; backend/chief-cc/bake.sh): a Freestyle VM from BASE (a hand
# snapshot with Claude Code and node), plus tailscale, the `chief` and `ccproxy` users, the turn runner
# (chief-turn-runner, Rust: Native/OptChat/chief-turn, built in the bake VM unless CHIEF_TURN_RUNNER_BIN names a
# linux x86_64 build),
# start.sh, boot.sh, proxy.mjs and its unit, chief-net (the Chief's network tool, net.ts), the Chief's
# cloud-route tools (msg 8200: gh, chief-vm, chief-agents, cmux and mac through the Mac gate, hub, cmux-ci)
# and cached clones of cmux (feat-cmux-next) and cmuxterm-hq (main) in /home/chief/work, then a snapshot
# named SLUG. The tailscale state is empty in the snapshot (each VM joins with its own one-use key at
# boot.sh), and no credential is left in it (the hq clone's token is used once from a root-only file).
# The bake VM is deleted.
#
#   FREESTYLE_KEY_FILE=~/.secrets/freestyle-...key HQ_DIR=~/fun/cmuxterm-hq backend/chief-cc/bake.sh SLUG [BASE] [UPSTREAM]
#
# HQ_DIR: a cmuxterm-hq checkout on main (tools/cloud-chief/vm/mac, tools/agent-hub/hub.py, build-fleet).
# The hq clone uses `gh auth token` of this machine for one clone; skip it with HQ_CLONE=0.
set -euo pipefail
slug="${1:?snapshot slug, e.g. cmuxnp-chiefcc-v1}"
base="${2:-sh-8d6654a2debb485da9d58da06291e7bd}" # cmuxnp-stg-hand-v4: claude 2.1.302, node 24
upstream="${3:-http://100.120.48.119:4016}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api="${CLOUD_FREESTYLE_API_URL:-https://api.freestyle.sh}"
keyfile="${FREESTYLE_KEY_FILE:?FREESTYLE_KEY_FILE}"
hq="${HQ_DIR:?HQ_DIR (a cmuxterm-hq checkout on main)}"
gh_version="${GH_VERSION:-2.102.1}"
auth() { printf 'header = "authorization: Bearer %s"\n' "$(cat "$keyfile")"; }
call() { curl -sS -m 600 -K <(auth) -H 'content-type: application/json' -X "$1" "$api$2" ${3:+--data-binary "$3"}; }
exec_root() { # exec_root COMMAND [STDIN_FILE]   (EXEC_MS: its time limit, default 300000)
  local body ms="${EXEC_MS:-300000}"
  if [[ -n "${2:-}" ]]; then body="$(jq -n --arg c "$1" --arg s "$(base64 < "$2" | tr -d '\n')" --argjson ms "$ms" '{command:$c, stdin:$s, timeoutMs:$ms, linuxUser:"root"}')"
  else body="$(jq -n --arg c "$1" --argjson ms "$ms" '{command:$c, timeoutMs:$ms, linuxUser:"root"}')"; fi
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
for f in proxy.mjs chief-net.mjs; do exec_root "cat > /opt/chief-cc/$f && chmod 644 /opt/chief-cc/$f" "$here/image/$f"; done
# The turn runner (Native/OptChat/chief-turn): the same Rust crate that reads Claude Code's stream for the Mac
# Chief host. Built here (rustup in /root, removed after) unless CHIEF_TURN_RUNNER_BIN is a linux x86_64 build.
if [[ -n "${CHIEF_TURN_RUNNER_BIN:-}" ]]; then
  exec_root 'base64 -d > /opt/chief-cc/chief-turn-runner && chmod 755 /opt/chief-cc/chief-turn-runner' <(base64 < "$CHIEF_TURN_RUNNER_BIN")
else
  runner_tar="$(mktemp)"
  tar --no-xattrs -C "$here/../../Native/OptChat/chief-turn" -czf "$runner_tar" Cargo.toml Cargo.lock src
  # The toolchain, then the build detached and polled (one exec may run at most 5 min).
  exec_root 'set -e; rm -rf /root/ctr && mkdir -p /root/ctr && base64 -d | tar -xz -C /root/ctr; command -v cc >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential >/dev/null; }; export RUSTUP_HOME=/root/ctr/rustup CARGO_HOME=/root/ctr/cargo; curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain stable --no-modify-path >/dev/null 2>&1; /root/ctr/cargo/bin/cargo --version' <(base64 < "$runner_tar")
  exec_root 'cd /root/ctr && RUSTUP_HOME=/root/ctr/rustup CARGO_HOME=/root/ctr/cargo setsid nohup sh -c "/root/ctr/cargo/bin/cargo build --release --locked --bin chief-turn-runner > /root/ctr/build.log 2>&1; echo \$? > /root/ctr/build.rc" < /dev/null > /dev/null 2>&1 & echo building'
  rc=""
  for _ in $(seq 1 90); do
    sleep 10
    rc="$(exec_root 'cat /root/ctr/build.rc 2>/dev/null || true')"
    [[ -n "$rc" ]] && break
  done
  [[ "$rc" == 0 ]] || { exec_root 'tail -30 /root/ctr/build.log' >&2 || true; echo "chief-turn-runner build failed (${rc:-timeout})" >&2; exit 1; }
  exec_root 'install -m 755 /root/ctr/target/release/chief-turn-runner /opt/chief-cc/chief-turn-runner && rm -rf /root/ctr'
  rm -f "$runner_tar"
fi
exec_root 'rc=0; /opt/chief-cc/chief-turn-runner ../x || rc=$?; [ "$rc" = 2 ] && echo "chief-turn-runner ok"'
for f in start.sh boot.sh; do exec_root "cat > /opt/chief-cc/$f && chmod 755 /opt/chief-cc/$f" "$here/image/$f"; done
exec_root 'printf "#!/bin/sh\nexec /opt/node/bin/node /opt/chief-cc/chief-net.mjs \"\$@\"\n" > /usr/local/bin/chief-net && chmod 755 /usr/local/bin/chief-net'
# The cloud-route tools (msg 8200 items 5-10, 13).
exec_root "cat > /opt/chief-cc/chief-vm.mjs && chmod 644 /opt/chief-cc/chief-vm.mjs" "$here/image/chief-vm.mjs"
exec_root 'printf "#!/bin/sh\nexec /opt/node/bin/node /opt/chief-cc/chief-vm.mjs \"\$@\"\n" > /usr/local/bin/chief-vm && chmod 755 /usr/local/bin/chief-vm'
exec_root "cat > /usr/local/bin/cmux && chmod 755 /usr/local/bin/cmux" "$here/image/cmux.sh"
exec_root "cat > /usr/local/bin/chief-agents && chmod 755 /usr/local/bin/chief-agents" "$here/image/chief-agents.sh"
exec_root "cat > /usr/local/bin/mac && chmod 755 /usr/local/bin/mac" "$hq/tools/cloud-chief/vm/mac"
exec_root "cat > /usr/local/lib/hub.py && chmod 644 /usr/local/lib/hub.py" "$hq/tools/agent-hub/hub.py"
exec_root 'printf "#!/bin/sh\nexec python3 /usr/local/lib/hub.py \"\$@\"\n" > /usr/local/bin/hub && chmod 755 /usr/local/bin/hub'
exec_root "command -v gh >/dev/null || { curl -fsSL https://github.com/cli/cli/releases/download/v${gh_version}/gh_${gh_version}_linux_amd64.tar.gz | tar -xz -C /tmp && install -m 755 /tmp/gh_${gh_version}_linux_amd64/bin/gh /usr/bin/gh && rm -rf /tmp/gh_${gh_version}_linux_amd64; }; gh --version | head -1"
fleet="$(mktemp)"
tar -C "$hq/build-fleet" -czf "$fleet" ci.sh ci-client.py fleet_client.py wait-job.py publish-hq.py feedback.py local_source.py dev_backend.py client_install.py archive_safety.py bundle_store.py install-client.py
exec_root 'rm -rf /tmp/fleet && mkdir -p /tmp/fleet && base64 -d | tar -xz -C /tmp/fleet && chown -R chief:chief /tmp/fleet && runuser -u chief -- python3 /tmp/fleet/install-client.py --prefix /home/chief/.local >/dev/null && rm -rf /tmp/fleet && ls -l /home/chief/.local/bin/cmux-ci' <(base64 < "$fleet")
rm -f "$fleet"
# Cached clones (item 13): each turn starts from these and fetches only what changed.
exec_root 'cd /home/chief/work && { [ -d cmux/.git ] || runuser -u chief -- git clone -q --depth 50 --single-branch --branch feat-cmux-next https://github.com/manaflow-ai/cmux cmux; } && runuser -u chief -- git -C cmux log --oneline -1'
if [[ "${HQ_CLONE:-1}" == 1 ]]; then
  tok="$(mktemp)"; chmod 600 "$tok"; gh auth token > "$tok"
  exec_root 'umask 077; t="$(cat)"; cd /home/chief/work && [ -d cmuxterm-hq/.git ] || runuser -u chief -- git -c "http.https://github.com/.extraheader=Authorization: Basic $(printf "x-access-token:%s" "$t" | base64 -w0)" clone -q --depth 50 --single-branch --branch main https://github.com/manaflow-ai/cmuxterm-hq cmuxterm-hq; unset t; runuser -u chief -- git -C cmuxterm-hq config --get-regexp "extraheader" && exit 9; runuser -u chief -- git -C cmuxterm-hq log --oneline -1' "$tok"
  rm -f "$tok"
fi
# Shell defaults (web/services/vms/images/shell/shell-defaults.sh): the devbox image's terminfo overlay
# (xterm-ghostty for htop/vim/tmux/less), hostname cmux, its prompt/bashrc and banner, UTF-8, truecolor and a
# TERM fallback. Baked here, never at boot.
shell_src="$here/../../web/services/vms/images"
shell_tar="$(mktemp)"
tar --no-xattrs -C "$shell_src" -czf "$shell_tar" shell/shell-defaults.sh shell/cmux-shell.sh shell/nvm-lazy.sh \
  devbox/cmux-terminfo.src devbox/cmux-terminfo.sh devbox/cmux-bashrc devbox/cmux-prompt.bash devbox/cmux-motd
exec_root 'rm -rf /tmp/cmux-shell && mkdir -p /tmp/cmux-shell/in && base64 -d | tar -xz -C /tmp/cmux-shell/in && cp /tmp/cmux-shell/in/shell/* /tmp/cmux-shell/in/devbox/* /tmp/cmux-shell/ && bash /tmp/cmux-shell/shell-defaults.sh /tmp/cmux-shell && rm -rf /tmp/cmux-shell && infocmp -x xterm-ghostty >/dev/null && hostname' <(base64 < "$shell_tar")
rm -f "$shell_tar"
exec_root 'df -h /home | tail -1'
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
