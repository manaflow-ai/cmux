#!/usr/bin/env bash
# TabsKit sync verification (verify/tabskit-sync.md): one recording of the
# workspace tabs with real HID touches (AXe), mock data, software keyboard.
# Steps: open workspace "cmux" (its last-used tab), grid out, open the
# terminal card, back to the list and reopen (lands on the terminal), grid,
# close the browser card, open the agent card, swipe the toolbar to the next
# tab and back, raise the keyboard on the agent composer and dismiss it with
# an interactive drag, then the same on the terminal.
# usage: verify/record-tabskit.sh <udid> <out-dir> <label>
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 dir=$2 label=$3
mkdir -p "$dir"
here=$(cd "$(dirname "$0")" && pwd)
xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl ui "$udid" appearance dark
xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
data=$(xcrun simctl get_app_container "$udid" dev.cmux.mobile data)
rm -f "$data/Documents/kbd-trace.txt"
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.mobile -cmuxMobile.setupComplete YES -cmux-mobile-kbd-trace >/dev/null
sleep 5

tap() { axe tap -x "$1" -y "$2" --tap-style physical --udid "$udid" >/dev/null; sleep "${3:-1.4}"; }
# Center of the first element whose label contains $1 (optional role $2).
at() { axe describe-ui --udid "$udid" | python3 -I "$here/scripts/ax_find.py" "$@"; }
# Waits up to 8 s for the element (a fresh install is slower to settle).
tap_label() {
  local p="" i
  for i in $(seq 16); do p=$(at "$1" "$2"); [[ -z "$p" ]] || break; sleep 0.5; done
  [[ -n "$p" ]] || { echo "not found: $1" >&2; return 1; }
  tap "${p% *}" "${p#* }" "${3:-1.4}"
}
shot() { axe screenshot --udid "$udid" --output "$dir/$label-$1.png" >/dev/null; }

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
sleep 0.8

tap_label Workspaces AXRadioButton
tap_label "cmux, " AXButton 2; shot 01-open-last-tab
tap_label Tabs AXButton 1.6; shot 02-grid
tap 297 245 1.6; shot 03-terminal-zoomed-in
tap_label Back AXButton 1.6
tap_label "cmux, " AXButton 2; shot 04-reopen-last-tab
tap_label Tabs AXButton 1.6
# The third card's close button (the browser tab).
tap_label "Close SwiftUI" AXButton 1.6 || tap 178 425 1.6
shot 05-closed-card
tap 105 245 1.6; shot 06-agent
# Swipe the toolbar label to the next tab and back (Safari's bottom-bar swipe).
axe drag --start-x 250 --start-y 816 --end-x 30 --end-y 816 --duration 0.35 --steps 20 --udid "$udid" >/dev/null; sleep 1.4
shot 07-swiped
axe drag --start-x 150 --start-y 816 --end-x 380 --end-y 816 --duration 0.35 --steps 20 --udid "$udid" >/dev/null; sleep 1.4
# Agent composer: keyboard up, then an interactive dismissal drag.
tap_label "Reply to Claude" AXButton 1.8; shot 08-agent-keyboard
axe drag --start-x 200 --start-y 250 --end-x 200 --end-y 860 --duration 1.6 --steps 96 --udid "$udid" >/dev/null; sleep 1.6
shot 09-agent-dismissed
# Terminal: keyboard up from the page, then the same drag.
axe drag --start-x 250 --start-y 816 --end-x 30 --end-y 816 --duration 0.35 --steps 20 --udid "$udid" >/dev/null; sleep 1.4
tap 200 400 1.8; shot 10-terminal-keyboard
axe drag --start-x 200 --start-y 250 --end-x 200 --end-y 860 --duration 1.6 --steps 96 --udid "$udid" >/dev/null; sleep 1.6
shot 11-terminal-dismissed
kill -INT $rec; wait $rec || true
trap - EXIT
cp "$data/Documents/kbd-trace.txt" "$dir/$label.trace.txt" 2>/dev/null || true
echo "$dir/$label.mp4"
