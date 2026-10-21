#!/usr/bin/env bash
# Round 1 of the Home and Chief implementation (../SPEC.md), on one headless
# simulator with real HID touches (axe), mock content (layout only):
# Home, the filter menu and its Unread / Needs You results, Chief from the
# pin (header avatar), Chief's details (and its Name page), compose opening
# Chief with the keyboard up, an agent chat's back button, and the team
# sidebar closed and open (with the accessibility tree saved each way).
# A screenshot per step; with `record`, a video of the whole walk.
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
# Center of the first element whose key (AXUniqueId, AXLabel) equals, or
# with "prefix" starts with, the value.
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

xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
for _ in 1 2 3 4; do axe describe-ui --udid "$udid" >/dev/null 2>&1 && break; sleep 3; done
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" "$bundle" -cmuxMobile.setupComplete YES -cmux-mobile-tab home >/dev/null
sleep 5
if [[ -n $record ]]; then
  log=$(mktemp)
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/walk.mp4" >"$log" 2>&1 &
  rec=$!
  trap 'kill -INT $rec 2>/dev/null || true; wait $rec 2>/dev/null || true' EXIT
  until grep -q "Recording started" "$log"; do sleep 0.1; done
fi
shot 01-home 0.6
tree 01-home-ax-sidebar-closed
tapid Filter AXLabel; shot 02-filter-menu
tapid "Needs You" AXLabel; shot 03-filter-needs-you
tapid Filter AXLabel; sleep 1; tapid Unread AXLabel; shot 04-filter-unread
tapid Filter AXLabel; sleep 1; tapid "All Conversations" AXLabel; sleep 1
tapid home.chief; shot 05-chief 2.5
tapid conversation.header.name; shot 06-details 1.8
axe swipe --start-x 200 --start-y 700 --end-x 200 --end-y 250 --duration 0.5 --udid "$udid" >/dev/null || true
shot 07-details-scrolled
tapid chief.settings.done; sleep 1.2
back; shot 08-home-after-back 1.5
tapid home.compose; shot 09-compose-opens-chief 2.0
back; sleep 1.5
tapid "cmux.com" AXLabel prefix; shot 10-agent-chat 2.0
back; sleep 1.5
tapid Teams AXLabel; shot 11-sidebar-open 1.5
tree 11-home-ax-sidebar-open
tapid "Close teams" AXLabel; shot 12-sidebar-closed 1.5
tree 12-home-ax-sidebar-closed-again
