#!/usr/bin/env bash
# Labeled comparison strips for the signed-out flow, ImageMagick only.
# usage: verify/login-montage.sh <evidence dir> <intro start seconds in s27-welcome-dark.mp4>
# Reads the recordings from verify/record-login.sh (plus s27-code-*.mp4) and,
# when present, refs/*.{jpg,png} and before-dark.png in the same directory.
set -euo pipefail
dir=$1 intro=$2
font=/System/Library/Fonts/Helvetica.ttc
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Last frame at or before t (the recorder writes frames only on change).
frame() { ffmpeg -loglevel quiet -y -i "$1" -vf "select='lte(t,$2)'" -fps_mode passthrough -update 1 "$3"; }
panel() {
  magick "$1" -resize x900 -background "#555" -gravity north -splice 0x40 \
    -font "$font" -pointsize 20 -fill white -gravity northwest -annotate +8+8 "$2" "$3"
}
strip() { local out=$1; shift; magick "$@" -background "#282828" -splice 8x0 +append "$out"; echo "$out"; }
cd "$dir"
n=0
add() { panel "$1" "$2" "$tmp/p$(printf %02d $n).png"; n=$((n + 1)); }

for v in s27-welcome-dark s27-welcome-light s26-welcome-dark s26-welcome-light; do frame "$v.mp4" 99 "$tmp/$v.png"; done
for v in s27-email-dark s27-email-light s26-email-dark s26-email-light s27-code-dark s27-code-light; do
  [[ -f $v.mp4 ]] && frame "$v.mp4" 99 "$tmp/$v.png"
done

# References | before | after.
n=0; rm -f "$tmp"/p*.png
for r in refs/*; do add "$r" "$(basename "${r%.*}")"; done
[[ -f before-dark.png ]] && add before-dark.png "before (dark)"
add "$tmp/s27-welcome-dark.png" "after iOS 27 dark"
add "$tmp/s27-welcome-light.png" "after iOS 27 light"
strip cmp-welcome.png "$tmp"/p*.png

# Every screen on both OS versions and appearances.
n=0; rm -f "$tmp"/p*.png
for v in s26-welcome-dark s26-welcome-light s27-welcome-dark s27-welcome-light s27-email-dark s27-email-light s26-email-dark s26-email-light s27-code-dark s27-code-light; do
  [[ -f $tmp/$v.png ]] && add "$tmp/$v.png" "$v"
done
strip cmp-matrix.png "$tmp"/p*.png

# Launch -> welcome, 10 frames 0.08 s apart from the intro start.
n=0; rm -f "$tmp"/p*.png
for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
  t=$(echo "$intro + $i * 0.08" | bc)
  frame s27-welcome-dark.mp4 "$t" "$tmp/f.png"
  add "$tmp/f.png" "+$(echo "$i * 0.08" | bc)s"
done
strip intro-s27-dark.png "$tmp"/p*.png
