#!/usr/bin/env bash
# Workspaces "Inbox" list walkthrough (verify/workspaces-design-loop.md) with
# real HID touches (axe), recorded: the list at launch, the Mac filter menu
# (each Mac, then All), an offline Mac's folded line expanded, an offline
# row's explanation, search, the row menu, swipe-left Close, New Workspace
# (tap and hold), and opening a needs-you workspace on its waiting tab.
# A screenshot per step plus 2 fps frames.
# usage: verify/record-wsdesign.sh <udid> <out-dir> [dark|light] [content-size]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 dir=$2 look=${3:-dark} size=${4:-large}
mkdir -p "$dir"
xcrun simctl ui "$udid" appearance "$look"
xcrun simctl ui "$udid" content_size "$size"
shot() { sleep "${2:-1}"; xcrun simctl io "$udid" screenshot "$dir/$1.png" >/dev/null 2>&1; echo "$1"; }
tap() { axe tap --udid "$udid" --wait-timeout 3 "$@" >/dev/null; }
at() { axe tap -x "$1" -y "$2" --udid "$udid" >/dev/null; }
hold() { axe touch -x "$1" -y "$2" --down --up --delay 1.2 --udid "$udid" >/dev/null; }
back() { axe drag --start-x 1 --start-y 450 --end-x 300 --end-y 450 --duration 0.5 --steps 40 --udid "$udid" >/dev/null; }
# Center of an element by accessibility id (or label with a second argument "label").
where() {
  axe describe-ui --udid "$udid" | python3 -c '
import json,sys
want,key=sys.argv[1],sys.argv[2]
def walk(n):
    if n.get(key)==want:
        f=n["frame"]; print(int(f["x"]+f["width"]/2), int(f["y"]+f["height"]/2)); sys.exit()
    for c in n.get("children") or []: walk(c)
for n in json.load(sys.stdin): walk(n)
sys.exit(1)' "$1" "${2:-AXUniqueId}"
}
# Scrolls the list until an element is on screen (above the tab bar).
reveal() {
  local x y
  for _ in 1 2 3 4 5 6; do
    if read -r x y < <(where "$1") && [ "$y" -lt 700 ] && [ "$y" -gt 220 ]; then echo "$x $y"; return; fi
    axe drag --start-x 200 --start-y 650 --end-x 200 --end-y 420 --duration 1.0 --steps 30 --udid "$udid" >/dev/null; sleep 0.8
  done
  where "$1"
}
top() { axe swipe --start-x 200 --start-y 300 --end-x 200 --end-y 750 --duration 0.3 --udid "$udid" >/dev/null; sleep 0.6; }
# Picks a Mac (or "all") in the filter menu by accessibility id.
filter() { sleep 0.5; tap --id workspaces.filter; sleep 1.5; read -r x y < <(where "workspaces.filter.$1"); at "$x" "$y"; }

xcrun simctl terminate "$udid" dev.cmux.mobile 2>/dev/null || true
# A fresh simulator's first automation session can time out: warm it up.
for _ in 1 2 3 4; do axe describe-ui --udid "$udid" >/dev/null 2>&1 && break; sleep 3; done
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.mobile \
  -cmuxMobile.setupComplete YES -cmux-mobile-tab workspaces -cmuxMobile.workspaces.macFilter.team-manaflow "" -cmux-mobile-mock-create-delay 8 >/dev/null
sleep 4
log=$(mktemp)
xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/walk.mp4" >"$log" 2>&1 &
rec=$!
trap 'kill -INT $rec 2>/dev/null || true' EXIT
until grep -q "Recording started" "$log"; do sleep 0.1; done
shot 01-list 0.5
tap --id workspaces.filter; shot 02-filter-menu
read -r x y < <(where workspaces.filter.mac-studio); at "$x" "$y"; shot 03-filter-studio
filter mbp; shot 04-filter-offline-mac
read -r x y < <(where workspace.row.ws-notes); at "$x" "$y"; shot 05-offline-explained
tap --label OK
filter all; shot 06-filter-all
read -r x y < <(reveal workspaces.fold.mbp); at "$x" "$y"; shot 07-offline-expanded
read -r x y < <(reveal workspace.row.ws-zed); at "$x" "$y"; shot 08-offline-row-tapped
tap --label OK
top
# Pull down until the search field shows under the bar, then tap it.
for _ in 1 2 3; do
  axe swipe --start-x 200 --start-y 260 --end-x 200 --end-y 620 --duration 1.0 --udid "$udid" >/dev/null; sleep 0.8
  if read -r x y < <(where Search AXLabel) && [ "$y" -gt 90 ]; then break; fi
done
shot 09-pulled-search 0.2
at "$x" "$y"
sleep 0.6; axe type "fix" --udid "$udid" >/dev/null
shot 10-search-results
tap --label Close --element-type Button || true
sleep 0.8; top
read -r x y < <(reveal workspace.row.ws-web); hold "$x" "$y"; shot 11-row-menu
axe key 41 --udid "$udid" >/dev/null; sleep 0.8
read -r x y < <(reveal workspace.row.ws-design)
axe swipe --start-x 340 --start-y "$y" --end-x 120 --end-y "$y" --duration 0.4 --udid "$udid" >/dev/null
shot 12-swipe-close
tap --id workspace.swipe.close; shot 13-close-confirm
# The popover must sit against the swiped row (just above or below it), at
# every text size: writes PASS or FAIL with the frames to check-13.txt.
axe describe-ui --udid "$udid" | python3 -c '
import json,sys
row=title=button=None
def walk(n):
    global row,title,button
    f=n.get("frame") or {}
    if n.get("AXUniqueId")=="workspace.row.ws-design": row=f
    label=n.get("AXLabel") or ""
    if label.startswith("Close \u201cdesign system\u201d?"): title=f
    if label=="Close Workspace": button=f
    for c in n.get("children") or []: walk(c)
for n in json.load(sys.stdin): walk(n)
if not (row and title and button):
    print("FAIL missing", row, title, button); sys.exit()
top=min(title["y"],button["y"]); bottom=max(title["y"]+title["height"],button["y"]+button["height"])
rt,rb=row["y"],row["y"]+row["height"]
gap=(rt-bottom) if bottom<=rt+10 else (top-rb)
# gap: from the row to the popover text (title above the buttons). The popover
# adds its own padding (more at accessibility sizes); negative means it covers the row.
print(("PASS" if -10<=gap<=160 else "FAIL"), "gap", round(gap,1), "row", round(rt,1), round(rb,1), "popover", round(top,1), round(bottom,1))
' | tee "$dir/check-13.txt"
tap --label "Close Workspace" --element-type Button; shot 14-closed 1.2
top
# Creations take 8 s here (-cmux-mobile-mock-create-delay): the pending row shows its spinner.
tap --id workspaces.new; shot 15-new-pushed 1.5
back; shot 16-new-pending 1.2
shot 16b-new-confirmed 6
read -r x y < <(where workspaces.new); hold "$x" "$y"; shot 17-new-options
# Dismiss the menu with a tap outside it (it opens on the right, under the button).
at 30 760; sleep 0.8
read -r x y < <(top; reveal workspace.row.ws-ghostty); at "$x" "$y"; shot 18-opened-waiting-tab 2
back; shot 19-back 1.5
kill -INT $rec; wait $rec || true
rm -rf "$dir/frames"; mkdir -p "$dir/frames"
ffmpeg -loglevel error -y -i "$dir/walk.mp4" -vf "fps=2,scale=300:-1" "$dir/frames/f%03d.png"
ls "$dir/frames" | wc -l
