#!/usr/bin/env bash
# Keyboard verification (verify/keyboard.md): open an agent chat with a
# DEBUG demo, then drive the keyboard with real HID touches (AXe) while
# `simctl io recordVideo` records and the app writes its per-frame trace
# (-cmux-mobile-kbd-trace). Steps: tap the composer (show), swipe down on the
# composer (dismiss), tap again (show), drag the transcript down past the
# composer (interactive dismissal).
# usage: verify/record-keyboard.sh <udid> <out-dir> <label> <demo>
#   demo: kbd-chat | kbd-chat-empty | kbd-tab | kbd-empty
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 dir=$2 label=$3 demo=$4
mkdir -p "$dir"
xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl ui "$udid" appearance dark
xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
data=$(xcrun simctl get_app_container "$udid" dev.cmux.mobile data)
rm -f "$data/Documents/kbd-trace.txt"
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.mobile -cmuxMobile.setupComplete YES -cmux-mobile-demo "$demo" -cmux-mobile-kbd-trace >/dev/null
sleep 5

field() {
  # The composer's field, or the collapsed capsule (both are labelled
  # "Reply to Claude"): a real touch at the lowest such element.
  local y
  y=$(composer_y)
  axe tap -x 150 -y "${y:-800}" --tap-style physical --udid "$udid" >/dev/null
}
composer_y() {
  axe describe-ui --udid "$udid" | python3 -I -c '
import json, sys
found = []
def walk(n):
    if n.get("AXLabel") == "Reply to Claude":
        f = n["frame"]; found.append(int(f["y"] + f["height"] / 2))
    for c in n.get("children", []): walk(c)
for n in json.load(sys.stdin): walk(n)
if found: print(max(found))'
}

swipe_composer() {
  local y
  y=$(composer_y)
  y=${y:-760}
  axe drag --start-x 330 --start-y "$y" --end-x 330 --end-y $((y + 160)) --duration 0.25 --steps 15 --udid "$udid" >/dev/null
}

log=$(mktemp)
# One simctl recording at a time per host ("Host recording is already in
# progress" while another session records): retry until this one starts.
for attempt in $(seq 60); do
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/$label.mp4" >"$log" 2>&1 &
  rec=$!
  for _ in $(seq 50); do grep -q "Recording started" "$log" && break; kill -0 $rec 2>/dev/null || break; sleep 0.1; done
  grep -q "Recording started" "$log" && break
  kill -INT $rec 2>/dev/null || true; wait $rec 2>/dev/null || true
  sleep 2
done
grep -q "Recording started" "$log" || { cat "$log"; exit 1; }
trap 'kill -INT $rec 2>/dev/null || true' EXIT
sleep 0.8
field
sleep 1.6
swipe_composer
sleep 1.6
field
sleep 1.6
axe drag --start-x 200 --start-y 250 --end-x 200 --end-y 860 --duration 1.6 --steps 96 --udid "$udid" >/dev/null
sleep 1.6
kill -INT $rec; wait $rec || true
cp "$data/Documents/kbd-trace.txt" "$dir/$label.trace.txt"
rm -rf "$dir/$label-frames"
"$(dirname "$0")/scripts/frames.sh" "$dir/$label.mp4" 0 60 "$dir/$label-frames" 1206 >/dev/null
echo "$dir/$label.mp4 $(ls "$dir/$label-frames" | wc -l | tr -d ' ') frames"
