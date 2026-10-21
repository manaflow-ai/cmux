#!/usr/bin/env bash
# Records the answer flow: Chief -> bar -> Allow -> Send Answer, mock content.
# usage: flow.sh <udid> <out.mp4> <dark|light> <content-size>
set -euo pipefail
udid=$1 out=$2 look=$3 size=$4
src=/tmp/r4/capture.sh
eval "$(sed -n '/^shot()/,/^tree()/p' $src)"
xcrun simctl ui "$udid" appearance "$look"; xcrun simctl ui "$udid" content_size "$size"
xcrun simctl terminate "$udid" dev.cmux.mobile 2>/dev/null || true
SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.mobile -cmuxMobile.setupComplete YES -cmux-mobile-tab home >/dev/null
sleep 5
tapid home.chief; sleep 2.5
log=$(mktemp); xcrun simctl io "$udid" recordVideo --codec h264 --force "$out" >"$log" 2>&1 & rec=$!
until grep -q "Recording started" "$log"; do sleep 0.1; done
sleep 0.8
tapid chief.question.bar; sleep 1.5
tapid Allow AXLabel; sleep 0.8
tapid chief.question.send; sleep 5
kill -INT $rec; wait $rec || true
