#!/usr/bin/env bash
# usage: flow.sh <udid> <out.mp4> <look> <closeSheet:0|1>
set -uo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
U=$1 out=$2 look=$3 close=$4
xcrun simctl ui $U appearance $look; xcrun simctl ui $U content_size large
where() { axe describe-ui --udid $U | python3 -c '
import json,sys
w,k,m=sys.argv[1],sys.argv[2],sys.argv[3]
def hit(v): return isinstance(v,str) and (v==w if m=="eq" else v.startswith(w))
def walk(n):
    if hit(n.get(k)): f=n["frame"]; print(int(f["x"]+f["width"]/2), int(f["y"]+f["height"]/2)); sys.exit()
    for c in n.get("children") or []: walk(c)
for n in json.load(sys.stdin): walk(n)
sys.exit(1)' "$1" "${2:-AXUniqueId}" "${3:-eq}"; }
tapid() { read -r x y < <(where "$@"); axe tap -x $x -y $y --udid $U >/dev/null; }
xcrun simctl terminate $U dev.cmux.mobile 2>/dev/null
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch $U dev.cmux.mobile -cmuxMobile.setupComplete YES -cmux-mobile-tab home >/dev/null; sleep 5
tapid home.chief; sleep 2.5
log=$(mktemp); xcrun simctl io $U recordVideo --codec h264 --force $out >$log 2>&1 & rec=$!
until grep -q "Recording started" $log; do sleep 0.1; done
sleep 0.8; tapid chief.question.bar; sleep 1.5
read -r ax ay < <(where "Allow, Runs" AXLabel prefix)
if [ "$close" = 1 ]; then cx_cy=$(where chief.question.close); fi
axe tap -x $ax -y $ay --udid $U >/dev/null
if [ "$close" = 1 ]; then read -r cx cy <<<"$cx_cy"; axe tap -x $cx -y $cy --udid $U >/dev/null; fi
sleep 5
kill -INT $rec; wait $rec
