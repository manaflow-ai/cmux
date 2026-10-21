#!/usr/bin/env bash
# Starts two identical services/conversation-sim servers (same SEED, same
# start instant, quiet knobs) from a checkout of the iMessage team's branch:
# 4870 feeds their lab host, 4871 feeds Chief, so a send on one side does not
# show up on the other and both transcripts stay identical.
# usage: verify/imsg-sims.sh <conversation-sim checkout root>
set -euo pipefail
root=$1
# Only the servers on these two ports (other sessions run their own).
for port in 4870 4871; do
  pids=$(lsof -ti "tcp:$port" -sTCP:LISTEN || true)
  [[ -n $pids ]] && kill $pids
  while lsof -ti "tcp:$port" -sTCP:LISTEN >/dev/null; do sleep 0.1; done
done
for port in 4870 4871; do
  (cd "$root" && PORT=$port HOST=127.0.0.1 SEED=1337 nohup bun run services/conversation-sim/server.ts >"/tmp/imsg-sim-$port.log" 2>&1 &)
done
quiet='{"latencyScale":0.2,"failRate":0,"historyFailRate":0,"duplicateRate":0,"disconnectEverySeconds":0,"botIntervalScale":100000,"botLinkRate":0,"effectRate":0,"statusEverySeconds":0,"focusEverySeconds":0,"botBackgroundRate":0,"pollVoteFailRate":0,"scheduledFailRate":0,"unsendFailRate":0}'
for port in 4870 4871; do
  until curl -sf "127.0.0.1:$port/healthz" >/dev/null; do sleep 0.2; done
  curl -sf -X POST "127.0.0.1:$port/admin/knobs" -d "$quiet" >/dev/null
done
echo "sims up on 4870 (ref) and 4871 (ours)"
