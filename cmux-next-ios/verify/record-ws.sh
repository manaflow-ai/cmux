#!/usr/bin/env bash
# Records the Workspaces and Chief demos on one headless simulator and splits
# frames. Needs a built app (verify/build.sh).
# usage: verify/record-ws.sh <udid> <label> [workspaces|chief|all] [light|dark]
# Workspaces: one recording across a relaunch (`-cmux-mobile-demo workspaces`, then
# terminate and `-cmux-mobile-demo workspaces-reopen`), so the reopened tab is checked
# in the same video.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
udid=$1 label=$2 which=${3:-all} mode=${4:-dark}
out="verify/evidence/$(date +%Y-%m-%d)/ws/$label"
mkdir -p "$out"
app=build/dd/Build/Products/Debug-iphonesimulator/CmuxMobileApp.app
xcrun simctl install "$udid" "$app"
# A running reference app (Messages) would add a back-to-app breadcrumb.
xcrun simctl terminate "$udid" com.apple.MobileSMS >/dev/null 2>&1 || true
xcrun simctl spawn "$udid" defaults write dev.cmux.mobile cmuxMobile.setupComplete -bool true
xcrun simctl ui "$udid" appearance "$mode"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
export SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1

record() { # name, then a function that drives the app
  local name=$1; shift
  local video="$out/$name-$mode.mp4" log
  log=$(mktemp)
  xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$video" >"$log" 2>&1 &
  local rec=$!
  until grep -q "Recording started" "$log"; do sleep 0.1; done
  "$@"
  kill -INT "$rec"; wait "$rec" || true
  mkdir -p "$out/$name-$mode-frames"
  ffmpeg -loglevel error -y -i "$video" -vf fps=2,scale=402:-1 "$out/$name-$mode-frames/f%04d.png"
  echo "$video"
}

drive_workspaces() {
  xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-demo workspaces >/dev/null
  sleep 40
  xcrun simctl terminate "$udid" dev.cmux.mobile
  sleep 1
  xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-demo workspaces-reopen >/dev/null
  sleep 11
}

drive_chief() {
  xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-demo chief >/dev/null
  sleep 38
}

case $which in
  workspaces) record workspaces drive_workspaces ;;
  chief) record chief drive_chief ;;
  all) record workspaces drive_workspaces; record chief drive_chief ;;
esac
