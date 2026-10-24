#!/usr/bin/env bash
# The fake agent on a rig Mac asks a permission every few seconds (as Codex or Claude Code
# would), driven from the laptop when the phone's mini cannot SSH to that rig.
#   live_feed_asks.sh HOST [SECONDS] [EVERY]
set -uo pipefail
host=${1:?host}; seconds=${2:-900}; every=${3:-6}
end=$(( $(date +%s) + seconds )); i=0
cmds=("git push origin main" "rm -rf build/" "npm publish" "cargo clippy --fix" "docker compose up -d" "swift test --parallel")
while (( $(date +%s) < end )); do
  ssh "$host" "cd ~/multimac-rig && python3 rig.py ask 'ask: ${cmds[$((i % 6))]} (#$i)'" >/dev/null 2>&1
  i=$((i + 1)); sleep "$every"
done
