#!/usr/bin/env bash
# Helpers for side-by-side runs of the iMessage team's lab host (REF) and
# Chief (OURS) on two headless simulators fed by verify/imsg-sims.sh.
# Source it, then: pair_setup <ref-udid> <ours-udid> <dark|light> <out-dir>;
# pair_launch; both <axe subcommand and args>; shot <name>.
# Gestures are real HID touches through `axe`, sent to both at once.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
REF_BUNDLE=${REF_BUNDLE:-dev.cmux.ios.imsgref}
OURS_BUNDLE=${OURS_BUNDLE:-dev.cmux.mobile}

pair_setup() {
  REF=$1 OURS=$2 MODE=$3 OUT=$4
  mkdir -p "$OUT"
  for u in "$REF" "$OURS"; do
    xcrun simctl ui "$u" appearance "$MODE"
    xcrun simctl ui "$u" content_size "${CONTENT_SIZE:-large}"
    xcrun simctl status_bar "$u" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
    # Answered up front, so a permission alert never covers a run (a stray
    # tap on the mic would otherwise raise one).
    for bundle in "$REF_BUNDLE" "$OURS_BUNDLE"; do
      for service in microphone photos; do xcrun simctl privacy "$u" grant "$service" "$bundle" >/dev/null 2>&1 || true; done
    done
    xcrun simctl terminate "$u" "$REF_BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl terminate "$u" "$OURS_BUNDLE" >/dev/null 2>&1 || true
  done
  xcrun simctl spawn "$OURS" defaults write dev.cmux.mobile cmuxMobile.setupComplete -bool true
}

pair_launch() {
  SIMCTL_CHILD_CMUX_UITEST_CONVERSATION_LAB='ws://127.0.0.1:4870/ws?conversation=direct' \
    xcrun simctl launch "$REF" "$REF_BUNDLE" >/dev/null
  SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 SIMCTL_CHILD_CMUX_MOBILE_CHIEF_SIM='ws://127.0.0.1:4871/ws?conversation=direct' \
    xcrun simctl launch "$OURS" "$OURS_BUNDLE" -cmux-mobile-demo chief-open >/dev/null
}

# Same gesture on both simulators at the same time.
# Waits only for its own two jobs (recordings run in the background too).
both() {
  axe "$@" --udid "$REF" >/dev/null 2>&1 &
  local a=$!
  axe "$@" --udid "$OURS" >/dev/null 2>&1 &
  wait $a $!
}

shot() {
  xcrun simctl io "$REF" screenshot "$OUT/$1-ref.png" >/dev/null 2>&1 &
  local a=$!
  xcrun simctl io "$OURS" screenshot "$OUT/$1-ours.png" >/dev/null 2>&1 &
  wait $a $!
}

rec_start() {
  REC_NAME=$1
  for side in ref ours; do
    u=$REF; [[ $side == ours ]] && u=$OURS
    log="$OUT/$1-$side.reclog"
    xcrun simctl io "$u" recordVideo --codec h264 --force "$OUT/$1-$side.mp4" >"$log" 2>&1 &
  done
  until grep -q "Recording started" "$OUT/$1-ref.reclog" && grep -q "Recording started" "$OUT/$1-ours.reclog"; do sleep 0.1; done
}

# xcrun's child simctl holds the recording: signal it, not the wrapper.
rec_stop() {
  pkill -INT -f "recordVideo --codec h264 --force $OUT/$REC_NAME-" || true
  while pgrep -f "recordVideo --codec h264 --force $OUT/$REC_NAME-" >/dev/null; do sleep 0.2; done
  rm -f "$OUT/$REC_NAME"-*.reclog
}

# Frames of a recording at <fps>, as a horizontal strip per side.
strip() {
  for side in ref ours; do
    rm -rf "$OUT/$1-$side-frames"; mkdir -p "$OUT/$1-$side-frames"
    ffmpeg -loglevel error -y -i "$OUT/$1-$side.mp4" -vf "fps=${2:-4},scale=220:-1" "$OUT/$1-$side-frames/f%03d.png"
  done
}
