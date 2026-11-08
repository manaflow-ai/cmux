#!/bin/zsh
# The Screen Sharing host for the iOS live rig: tagged cmux NEXT signed in as the
# agent test account (TCC inherited from this mini's cmux.app), plus InputProbe.
set -u
dir=~/iss-rig
tag=${1:-issmac1}
app="$dir/$tag/cmux DEV $tag.app"
mkdir -p "$dir/state-$tag"
[[ -f "$dir/state-$tag/cmux.json" ]] || echo "{}" > "$dir/state-$tag/cmux.json"
"$dir/InputProbe" "$dir/probe-$tag.jsonl" > "$dir/probe-$tag.log" 2>&1 &
exec env CMUX_NEXT_NO_ACTIVATE=1 CMUX_NEXT_SOCKET_MODE=automation CMUX_NEXT_TEST_WINDOW_SCREEN=last \
  CMUX_AUTH_CREDENTIALS_FILE="$dir/private/creds.env" \
  CMUX_NEXT_CONFIG_FILE="$dir/state-$tag/cmux.json" CMUX_NEXT_TEST_WINDOW_FRAME=1300,80,600,500 \
  "$app/Contents/MacOS/cmux DEV" > "$dir/host-$tag.log" 2>&1
