# Shared helpers for seed*.sh: k = Kate (theirs), a = Aziz (mine); the second arg is replyToIndex back from the newest.
P=4871
curl -sf -m 10 -X POST 127.0.0.1:$P/admin/knobs -d '{"latencyScale":0.2,"failRate":0,"historyFailRate":0,"duplicateRate":0,"disconnectEverySeconds":0,"botIntervalScale":100000,"botLinkRate":0,"effectRate":0,"statusEverySeconds":0,"focusEverySeconds":0,"botBackgroundRate":0}' >/dev/null
post() { curl -sf -m 10 -X POST "127.0.0.1:$P/admin/say" -H 'content-type: application/json' -d "$1" >/dev/null; }
k() { post "{\"conversation\":\"empty\",\"senderId\":\"kate\",\"text\":\"$1\",\"quiet\":${QUIET:-true}${2:+,\"replyToIndex\":$2}}"; }
a() { post "{\"conversation\":\"empty\",\"senderId\":\"aziz\",\"text\":\"$1\",\"quiet\":${QUIET:-true}${2:+,\"replyToIndex\":$2}}"; }
