#!/bin/bash
# Restarts conversation-sim on 4871 (repo checkout $SIMROOT, default wt-base),
# seeds its "empty" conversation (Kate) like refseed.sh and opens Chief on it.
set -e
source ~/imsgreply/udids
P=4871; ROOT=${SIMROOT:-$HOME/imsgreply/wt-base}
pkill -f "conversation-sim/server.ts" 2>/dev/null || true
for i in $(seq 1 100); do lsof -ti tcp:$P -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.1; done
(cd $ROOT && PORT=$P HOST=127.0.0.1 SEED=1337 exec nohup ~/imsgreply/bun/bin/bun run services/conversation-sim/server.ts) > /tmp/imsgreply-sim.log 2>&1 < /dev/null &
for i in $(seq 1 300); do curl -sf -m 2 127.0.0.1:$P/healthz >/dev/null && break; sleep 0.2; done
curl -sf -m 10 -X POST 127.0.0.1:$P/admin/knobs -d '{"latencyScale":0.2,"failRate":0,"historyFailRate":0,"duplicateRate":0,"disconnectEverySeconds":0,"botIntervalScale":100000,"botLinkRate":0,"effectRate":0,"statusEverySeconds":0,"focusEverySeconds":0,"botBackgroundRate":0}' >/dev/null
post() { curl -sf -m 10 -X POST "127.0.0.1:$P/admin/say" -H 'content-type: application/json' -d "$1" >/dev/null; }
post '{"conversation":"empty","senderId":"kate","text":"Are we still on for dinner tonight","quiet":true}'
post '{"conversation":"empty","senderId":"kate","text":"I was thinking the Thai place on Main Street since they have that patio now and it should be really nice out tonight","quiet":true}'
post '{"conversation":"empty","senderId":"kate","text":"Let me know by five","quiet":true}'
post '{"conversation":"empty","senderId":"aziz","text":"Yes Thai sounds perfect","quiet":true}'
post '{"conversation":"empty","senderId":"aziz","text":"Booking for seven","quiet":true}'
xcrun simctl terminate $OURS dev.cmux.mobile 2>/dev/null || true
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 SIMCTL_CHILD_CMUX_MOBILE_CHIEF_SIM="ws://127.0.0.1:$P/ws?conversation=empty" xcrun simctl launch $OURS dev.cmux.mobile -cmux-mobile-demo chief-open >/dev/null
~/.local/bin/axe tap --label "Message Chief" --wait-timeout 15 --udid $OURS >/dev/null 2>&1 || true
