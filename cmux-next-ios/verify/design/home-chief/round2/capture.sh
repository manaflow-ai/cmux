#!/usr/bin/env bash
# Round 2 of the Home and Chief implementation (../REVIEW-round1.md F1-F7 and
# the queued phone items), on one headless simulator with real HID touches
# (axe). MOCK CONTENT, LAYOUT ONLY: no Mac, no pairing. The mock Chief's
# "Face ID" is a pause (nothing is signed); the pairing banner is forced
# with the DEBUG launch argument -cmux-mobile-banner-demo.
# Steps: Home (pin bubble clear of search), Needs You with Chief, Chief with
# its question bar, the question sheet, Waiting for Face ID…, Sending…,
# the answered transcript, the details page, and the two-line pairing banner.
# usage: capture.sh <udid> <out-dir> <dark|light> <content-size> [record]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 dir=$2 look=$3 size=$4 record=${5:-}
bundle=dev.cmux.mobile
mkdir -p "$dir"
xcrun simctl ui "$udid" appearance "$look"
xcrun simctl ui "$udid" content_size "$size"
shot() { sleep "${2:-1.2}"; xcrun simctl io "$udid" screenshot "$dir/$1.png" >/dev/null 2>&1; echo "$1"; }
at() { axe tap -x "$1" -y "$2" --udid "$udid" >/dev/null; }
back() { axe drag --start-x 1 --start-y 450 --end-x 300 --end-y 450 --duration 0.5 --steps 40 --udid "$udid" >/dev/null; }
where() {
  axe describe-ui --udid "$udid" | python3 -c '
import json,sys
want,key,mode=sys.argv[1],sys.argv[2],sys.argv[3]
def hit(v): return isinstance(v,str) and (v==want if mode=="eq" else v.startswith(want))
def walk(n):
    if hit(n.get(key)):
        f=n["frame"]; print(int(f["x"]+f["width"]/2), int(f["y"]+f["height"]/2)); sys.exit()
    for c in n.get("children") or []: walk(c)
for n in json.load(sys.stdin): walk(n)
sys.exit(1)' "$1" "${2:-AXUniqueId}" "${3:-eq}"
}
tapid() { local x y; read -r x y < <(where "$@"); at "$x" "$y"; }
tree() { axe describe-ui --udid "$udid" > "$dir/$1.json"; }
launch() {
  xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
  SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" "$bundle" -cmuxMobile.setupComplete YES "$@" >/dev/null
  sleep 5
}

for _ in 1 2 3 4; do axe describe-ui --udid "$udid" >/dev/null 2>&1 && break; sleep 3; done
launch -cmux-mobile-tab home
if [[ -n $record ]]; then
  log=$(mktemp)
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/full.mp4" >"$log" 2>&1 &
  rec=$!
  trap 'kill -INT $rec 2>/dev/null || true; wait $rec 2>/dev/null || true' EXIT
  until grep -q "Recording started" "$log"; do sleep 0.1; done
fi
shot 01-home 0.6
tree 01-home-ax
tapid Filter AXLabel; sleep 1; tapid "Needs You" AXLabel; shot 02-needs-you-with-chief
tapid Filter AXLabel; sleep 1; tapid "All Conversations" AXLabel; sleep 1
tapid home.chief; shot 03-chief-question-bar 2.5
tapid chief.question.bar; shot 04-question-sheet 1.5
tree 04-question-sheet-ax
tapid "Allow, Runs" AXLabel prefix; shot 05-waiting-for-face-id 0.3
shot 06-sending 1.4
shot 07-answered 2.5
tapid conversation.header.name; shot 08-details 1.8
tapid chief.settings.done; sleep 1.2
if [[ -n $record ]]; then kill -INT $rec; wait $rec 2>/dev/null || true; trap - EXIT; fi
launch -cmux-mobile-tab workspaces -cmux-mobile-banner-demo pairing
shot 09-pairing-banner 0.5
launch -cmux-mobile-tab workspaces -cmux-mobile-banner-demo pairing-reset
shot 10-pairing-banner-reset 0.5
