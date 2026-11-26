#!/usr/bin/env bash
# Take golden screenshots of the NEXT iOS app's fixture screens on a Mac simulator.
#
#   shots.sh simctl OUT_DIR APP_PATH   # SIM_UDID names the simulator (default: booted)
#
# The app must be installed already (simctl install). For each row of screens.tsv it sets the
# appearance, relaunches the app on that fixture screen and waits for a settled frame (two screenshots in a row
# with the same bytes, after SETTLE_S), then writes OUT_DIR/NAME.png. OUT_DIR/meta.json records the backend,
# model, scale and effects that compare.py reads. EFFECTS (full | reduced) is recorded as given; the caller sets it.
#
# ios-sim-linux-build.yml uploads them (with screens.tsv) as ios-sim-mac-shots, the reference a screenshot run on
# another simulator is compared with, launch for launch.
set -euo pipefail

backend=${1:?backend: simctl}
out=${2:?out dir}
app=${3:?app path}
here=$(cd "$(dirname "$0")" && pwd)
screens=${SCREENS_TSV:-$here/screens.tsv}
settle=${SETTLE_S:-6}
tries=${STABLE_TRIES:-10}
model=${MODEL:-iPhone 17 Pro}
effects=${EFFECTS:-unknown}
only=${ONLY:-}
mkdir -p "$out"

bundle=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1] + "/Info.plist","rb"))["CFBundleIdentifier"])' "$app")
args=(-cmuxMobile.setupComplete YES -cmux-mobile-no-restore)

case "$backend" in
  simctl)
    udid=${SIM_UDID:-booted}
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charging --batteryLevel 100 || true
    appearance() { xcrun simctl ui "$udid" appearance "$1"; }
    shoot() { xcrun simctl io "$udid" screenshot --type=png "$1" >/dev/null 2>&1; }
    stop() { xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true; }
    start() {
      local envs=() kv
      for kv in "$@"; do envs+=("SIMCTL_CHILD_$kv"); done
      env "${envs[@]}" xcrun simctl launch "$udid" "$bundle" "${args[@]}" >/dev/null
    }
    ;;
  *) echo "unknown backend $backend" >&2; exit 2 ;;
esac

hash_of() { python3 -c 'import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

current_appearance=""
failed=0
while IFS=$'\t' read -r name look envline; do
  case "$name" in ''|'#'*) continue ;; esac
  if [ -n "$only" ] && ! grep -qw -- "$name" <<<"$only"; then continue; fi
  if [ "$look" != "$current_appearance" ]; then
    appearance "$look"
    current_appearance=$look
  fi
  stop
  read -r -a kvs <<<"$envline"
  t0=$(date +%s)
  if ! start "${kvs[@]}"; then
    echo "$name: launch failed" >&2
    failed=$((failed + 1))
    continue
  fi
  sleep "$settle"
  prev="" ok=0
  for i in $(seq 1 "$tries"); do
    if shoot "$out/$name.png.tmp"; then
      h=$(hash_of "$out/$name.png.tmp")
      if [ "$h" = "$prev" ]; then ok=1; break; fi
      prev=$h
    fi
    sleep 2
  done
  if [ -f "$out/$name.png.tmp" ]; then
    mv "$out/$name.png.tmp" "$out/$name.png"
    echo "$name: $(( $(date +%s) - t0 ))s$([ $ok = 1 ] || echo ' (never settled)')"
  else
    echo "$name: no screenshot" >&2
    failed=$((failed + 1))
  fi
done <"$screens"
stop

python3 - "$out" "$backend" "$model" "$effects" <<'EOF'
import json, os, struct, sys
out, backend, model, effects = sys.argv[1:]
pngs = sorted(f for f in os.listdir(out) if f.endswith(".png"))
w = h = None
if pngs:
    with open(os.path.join(out, pngs[0]), "rb") as f:
        w, h = struct.unpack(">II", f.read(24)[16:24])
points_w = {1206: 402, 804: 402, 1320: 440, 880: 440}.get(w)
scale = round(w / points_w) if points_w else None
json.dump({"backend": backend, "model": model, "effects": effects, "px": [w, h], "points_w": points_w,
           "scale": scale, "screens": [p[:-4] for p in pngs]}, open(os.path.join(out, "meta.json"), "w"), indent=2)
EOF
[ "$failed" = 0 ] || { echo "$failed screen(s) failed" >&2; exit 1; }
