#!/usr/bin/env bash
# Real agents on a rig Mac on another mini, driven from the laptop (live_feed.py's --agents-rig
# when the minis cannot SSH to each other): launches the rig, then a Codex and a Claude session
# (acpmux harnesses `codex` and `claude-sr2`) each work through prompts until SECONDS pass.
#
#   live_feed_agents.sh HOST [SECONDS]
set -uo pipefail
host=${1:?host}; seconds=${2:-900}
ssh "$host" "cd ~/multimac-rig && python3 rig.py launch" | tail -1
end=$(( $(date +%s) + seconds ))
run() {
  local harness=$1; shift
  local name="feedperf-$harness-$(date +%s)" first=1
  while (( $(date +%s) < end )); do
    for prompt in "$@"; do
      (( $(date +%s) < end )) || break
      if (( first )); then
        ssh "$host" "cd ~/multimac-rig && python3 rig.py acpmux new -m $harness -n $name --cwd /Users/cmux/multimac-rig/work $(printf '%q' "$prompt")" >/dev/null 2>&1
        first=0
      else
        ssh "$host" "cd ~/multimac-rig && python3 rig.py acpmux send $name $(printf '%q' "$prompt")" >/dev/null 2>&1
      fi
      echo "$(date +%T) $host $harness: $prompt"
    done
  done
}
run codex \
  "List the files in this folder, then write a short Python script that counts words in a file, and show it in a code block." \
  "Run \`uname -a\` and \`sw_vers\`, then summarize the machine in a markdown table." \
  "Explain the difference between a merge and a rebase in git, with a small example of each in code blocks." &
run claude-sr2 \
  "Write a Swift function that parses ISO 8601 dates, with a short explanation and a usage example." \
  "Run \`ls -la\` and \`df -h\`, then tell me in a markdown table which volume has the most free space." \
  "Draft a three-step plan to profile a SwiftUI list that hitches, with a code block for the Instruments command." &
wait
