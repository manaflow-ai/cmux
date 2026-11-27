#!/usr/bin/env bash
# Home and Workspaces search, recorded in the same states with the same real
# HID touches (axe): at rest, pulled down to reveal the search field, the
# field focused with a query typed, and cancelled. One video per tab, a
# screenshot per state, then a side-by-side video and a contact sheet.
# usage: verify/record-home-search.sh <udid> <out-dir> [dark|light] [content-size] [query]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 dir=$2 look=${3:-dark} size=${4:-large} query=${5:-cmux}
mkdir -p "$dir"
xcrun simctl ui "$udid" appearance "$look"
xcrun simctl ui "$udid" content_size "$size"
# Fixed pacing (not polling): the same waits on both tabs so the videos line up.
shot() { sleep "${2:-1}"; xcrun simctl io "$udid" screenshot "$dir/$1.png" >/dev/null 2>&1; echo "$1"; }
at() { axe tap -x "$1" -y "$2" --udid "$udid" >/dev/null; }
where() {
  axe describe-ui --udid "$udid" | python3 -c '
import json,sys
want,key=sys.argv[1],sys.argv[2]
def walk(n):
    if n.get(key)==want and (n.get("frame") or {}).get("y",0)>0:
        f=n["frame"]; print(int(f["x"]+f["width"]/2), int(f["y"]+f["height"]/2)); sys.exit()
    for c in n.get("children") or []: walk(c)
for n in json.load(sys.stdin): walk(n)
sys.exit(1)' "$1" "${2:-AXLabel}"
}

run() { # tab
  local tab=$1 x y
  xcrun simctl terminate "$udid" dev.cmux.mobile 2>/dev/null || true
  axe describe-ui --udid "$udid" >/dev/null 2>&1 || true
  SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.mobile \
    -cmuxMobile.setupComplete YES -cmux-mobile-tab "$tab" -cmuxMobile.workspaces.macFilter.team-manaflow "" >/dev/null
  sleep 5
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/$tab.mp4" >/dev/null 2>&1 &
  local rec=$!
  sleep 2
  shot "$tab-1-rest" 0.5
  # One deliberate pull from under the bar, the same on both tabs.
  axe swipe --start-x 200 --start-y 260 --end-x 200 --end-y 620 --duration 1.0 --udid "$udid" >/dev/null
  shot "$tab-2-pulled" 1.2
  axe describe-ui --udid "$udid" > "$dir/$tab-2-pulled.ui.json"
  read -r x y < <(where Search)
  at "$x" "$y"
  shot "$tab-3-focused" 1.0
  axe type "$query" --udid "$udid" >/dev/null
  shot "$tab-4-query" 1.2
  axe describe-ui --udid "$udid" > "$dir/$tab-4-query.ui.json"
  if read -r x y < <(where Cancel); then at "$x" "$y"; else read -r x y < <(where Close); at "$x" "$y"; fi
  shot "$tab-5-cancelled" 1.5
  shot "$tab-6-settled" 1.5
  kill -INT $rec; wait $rec || true
}

run home
run workspaces
# Side by side (Home left, Workspaces right), and 4 fps frames of it.
ffmpeg -loglevel error -y -i "$dir/home.mp4" -i "$dir/workspaces.mp4" \
  -filter_complex "[0:v]scale=-2:900[a];[1:v]scale=-2:900[b];[a][b]hstack=inputs=2:shortest=1" \
  -c:v libx264 -pix_fmt yuv420p "$dir/side-by-side.mp4"
rm -rf "$dir/frames"; mkdir -p "$dir/frames"
ffmpeg -loglevel error -y -i "$dir/side-by-side.mp4" -vf "fps=4" "$dir/frames/f%03d.png"
# Contact sheet: one row per state, Home left, Workspaces right.
args=()
for s in 1-rest 2-pulled 3-focused 4-query 5-cancelled 6-settled; do
  args+=(-i "$dir/home-$s.png" -i "$dir/workspaces-$s.png")
done
ffmpeg -loglevel error -y "${args[@]}" -filter_complex "$(python3 -c '
n=12
parts=[f"[{i}:v]scale=300:-2[s{i}]" for i in range(n)]
parts.append("".join(f"[s{i}]" for i in range(n))+"xstack=inputs=12:layout="+"|".join(f"{(i%2)*300}_{(i//2)*652}" for i in range(n))+"[out]")
print(";".join(parts))')" -map "[out]" "$dir/contact-sheet.png"
echo "done: $dir"
