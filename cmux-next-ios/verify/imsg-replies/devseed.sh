#!/bin/bash
# The 2026-10-30 device screenshot's conversation in conversation-sim's
# "empty" chat (Kate stands in for Austin), dark mode, then Chief opens on it.
# usage: devseed.sh [port]
set -e
source ~/imsgreply/udids
P=${1:-4871}; ROOT=${SIMROOT:-$HOME/imsgreply/wt-base}
# Stop the conversation-sim this script started last time, by its recorded PID (never by name:
# another run's server on this Mac is not ours).
SIMPID=/tmp/imsgreply-sim.pid
p=$(cat $SIMPID 2>/dev/null) && ps -p "$p" -o command= 2>/dev/null | grep -q "conversation-sim/server.ts" && kill "$p" 2>/dev/null || true
for i in $(seq 1 100); do lsof -ti tcp:$P -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.1; done
(cd $ROOT && PORT=$P HOST=127.0.0.1 SEED=1337 exec nohup ~/imsgreply/bun/bin/bun run services/conversation-sim/server.ts) > /tmp/imsgreply-sim.log 2>&1 < /dev/null &
echo $! > $SIMPID
for i in $(seq 1 300); do curl -sf -m 2 127.0.0.1:$P/healthz >/dev/null && break; sleep 0.2; done
curl -sf -m 10 -X POST 127.0.0.1:$P/admin/knobs -d '{"latencyScale":0.2,"failRate":0,"historyFailRate":0,"duplicateRate":0,"disconnectEverySeconds":0,"botIntervalScale":100000,"botLinkRate":0,"effectRate":0,"statusEverySeconds":0,"focusEverySeconds":0,"botBackgroundRate":0}' >/dev/null
post() { curl -sf -m 10 -X POST "127.0.0.1:$P/admin/say" -H 'content-type: application/json' -d "$1" >/dev/null; }
post '{"conversation":"empty","senderId":"kate","text":"how about the cmux cloud dogfooding","quiet":true}'
post '{"conversation":"empty","senderId":"aziz","text":"ill merge ok?","quiet":true}'
post '{"conversation":"empty","senderId":"kate","text":"Do u know how to do this properlyv","replyToIndex":0,"quiet":true}'
post '{"conversation":"empty","senderId":"kate","text":"Ask your agents how to do it safely","quiet":true}'
post '{"conversation":"empty","senderId":"kate","text":"yes u can merge if they are good - we will cut release tonight","quiet":true}'
post '{"conversation":"empty","senderId":"aziz","text":"we just need to get the release out at around the same time as the merge","replyToIndex":3,"quiet":true}'
post '{"conversation":"empty","senderId":"aziz","text":"still going","replyToIndex":5,"quiet":true}'
post '{"conversation":"empty","senderId":"kate","text":"If any bugs send video","quiet":true}'
xcrun simctl ui $OURS appearance dark
xcrun simctl terminate $OURS dev.cmux.mobile 2>/dev/null || true
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 SIMCTL_CHILD_CMUX_MOBILE_CHIEF_SIM="ws://127.0.0.1:$P/ws?conversation=empty" xcrun simctl launch $OURS dev.cmux.mobile -cmux-mobile-demo chief-open >/dev/null
