#!/usr/bin/env bash
# Jump-to-bottom verification (verify/jump-button.md): open an agent chat
# with a DEBUG demo, then swipe the transcript down with real HID touches
# (AXe) while `simctl io recordVideo` records and the app writes its
# per-frame trace (-cmux-mobile-kbd-trace, which includes the jump button).
# usage: verify/record-jump.sh <udid> <out-dir> <label> <demo> [keyboard]
#   demo: kbd-empty (empty tab) | kbd-chat-empty (empty pushed) | kbd-tab | kbd-chat
#   keyboard: "up" keeps the keyboard up, so the swipes are interactive
#   dismissals; anything else dismisses it first.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 dir=$2 label=$3 demo=$4 keyboard=${5:-down}
mkdir -p "$dir"
xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl ui "$udid" appearance dark
xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
data=$(xcrun simctl get_app_container "$udid" dev.cmux.mobile data)
rm -f "$data/Documents/kbd-trace.txt"
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.mobile -cmuxMobile.setupComplete YES -cmux-mobile-demo "$demo" -cmux-mobile-kbd-trace >/dev/null
sleep 6

composer_y() {
  axe describe-ui --udid "$udid" | python3 -I -c '
import json, sys
found = []
def walk(n):
    if (n.get("AXLabel") or "").startswith("Reply to"):
        f = n["frame"]; found.append(int(f["y"] + f["height"] / 2))
    for c in n.get("children", []): walk(c)
for n in json.load(sys.stdin): walk(n)
if found: print(max(found))'
}
y=$(composer_y); y=${y:-760}
if [ "$keyboard" = up ]; then
  axe tap -x 150 -y "$y" --tap-style physical --udid "$udid" >/dev/null
else
  # New tabs open focused: drag the transcript down past the composer
  # (interactive dismissal) to take the keyboard down.
  axe drag --start-x 200 --start-y 250 --end-x 200 --end-y 860 --duration 1.2 --steps 72 --udid "$udid" >/dev/null
fi
sleep 1.5

log=$(mktemp)
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
sleep 0.6
# "Swipe down arbitrarily": a quick flick, a slow pull, and one off-centre.
axe drag --start-x 200 --start-y 260 --end-x 210 --end-y 560 --duration 0.25 --steps 15 --udid "$udid" >/dev/null
sleep 1.2
axe drag --start-x 160 --start-y 300 --end-x 170 --end-y 700 --duration 0.9 --steps 54 --udid "$udid" >/dev/null
sleep 1.2
axe drag --start-x 300 --start-y 420 --end-x 290 --end-y 640 --duration 0.35 --steps 21 --udid "$udid" >/dev/null
sleep 1.4
kill -INT $rec; wait $rec || true
cp "$data/Documents/kbd-trace.txt" "$dir/$label.trace.txt" 2>/dev/null || true
rm -rf "$dir/$label-frames"
"$(dirname "$0")/scripts/frames.sh" "$dir/$label.mp4" 0 60 "$dir/$label-frames" 402 >/dev/null
echo "$dir/$label.mp4 $(ls "$dir/$label-frames" | wc -l | tr -d ' ') frames"
