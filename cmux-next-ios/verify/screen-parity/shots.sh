#!/usr/bin/env bash
# Take golden screenshots of the NEXT iOS app's fixture screens on a Mac simulator.
#
#   shots.sh fleet OUT_DIR SHA         # on a fleet simulator Mac, from any host with cmux-ci
#   shots.sh simctl OUT_DIR APP_PATH   # on this Mac; SIM_UDID names the simulator (default: booted)
#
# fleet hands the rows of screens.tsv to the build fleet's `shots` step (scripts/ci/cmux-next-ios-sim.sh, class
# simulator): it builds the app at SHA, boots MODEL, overrides the status bar to 9:41 and takes each scene in light
# and dark after SETTLE_S. The NAME-light and NAME-dark rows are one scene there and must share their environment.
# It writes the same OUT_DIR/NAME.png and meta.json as simctl, plus the step's SUMMARY.md. No Mac or Xcode is
# needed on this host.
#
# simctl needs the app installed already (simctl install). For each row of screens.tsv it sets the appearance,
# relaunches the app on that fixture screen and waits for a settled frame (two screenshots in a row with the same
# bytes, after SETTLE_S), then writes OUT_DIR/NAME.png.
#
# OUT_DIR/meta.json records the backend, model, scale and effects that compare.py reads. EFFECTS (full | reduced)
# is recorded as given; the caller sets it.
#
# ios-sim-linux-build.yml (job shots-fleet) runs fleet and uploads the shots (with screens.tsv) as
# ios-sim-mac-shots, the reference a screenshot run on another simulator is compared with, launch for launch.
set -euo pipefail

backend=${1:?backend: fleet or simctl}
out=${2:?out dir}
target=${3:?app path (simctl) or commit SHA (fleet)}
here=$(cd "$(dirname "$0")" && pwd)
screens=${SCREENS_TSV:-$here/screens.tsv}
settle=${SETTLE_S:-6}
tries=${STABLE_TRIES:-10}
model=${MODEL:-iPhone 17 Pro}
effects=${EFFECTS:-unknown}
only=${ONLY:-}
mkdir -p "$out"

write_meta() {
  python3 - "$out" "$backend" "$model" "$effects" <<'PY'
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
PY
}

# The rows to take: name, appearance, environment (tab-separated), comments and ONLY applied.
rows() {
  local name look envline
  while IFS=$'\t' read -r name look envline; do
    case "$name" in ''|'#'*) continue ;; esac
    if [ -n "$only" ] && ! grep -qw -- "$name" <<<"$only"; then continue; fi
    printf '%s\t%s\t%s\n' "$name" "$look" "$envline"
  done <"$screens"
}

if [ "$backend" = fleet ]; then
  sha=$target
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "fleet: want a full commit SHA, got '$sha'" >&2; exit 2; }
  client=${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}
  [ -x "$client" ] || client=$(command -v cmux-ci || true)
  [ -n "$client" ] || { echo "fleet: cmux-ci is not installed" >&2; exit 2; }
  # One scene per NAME: --arg NAME=SHOT_WAIT=S,ENV=VALUE,... (fleet step arguments hold no spaces).
  # (No associative arrays: a macOS runner's bash is 3.2.)
  scene_args=() seen=$'\n'
  while IFS=$'\t' read -r name look envline; do
    base=${name%-"$look"}
    [ "$base-$look" = "$name" ] || { echo "screens.tsv: $name: name fleet rows BASE-light / BASE-dark" >&2; exit 2; }
    words=$(tr -s ' ' ',' <<<"$envline")
    scene="$base=SHOT_WAIT=$settle${words:+,$words}"
    case "$seen" in
      *$'\n'"$scene"$'\n'*) continue ;;
      *$'\n'"$base="*) echo "screens.tsv: $base: light and dark differ in environment" >&2; exit 2 ;;
    esac
    seen="$seen$scene"$'\n'
    scene_args+=(--arg "$scene")
  done < <(rows)
  [ ${#scene_args[@]} -gt 0 ] || { echo "fleet: no rows to take" >&2; exit 2; }
  log="$out/fleet-step.log"
  scratch="$out/.fleet"
  rm -rf "$scratch"
  mkdir -p "$scratch"
  status=0
  "$client" run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref "$sha" \
    --timeout "${FLEET_TIMEOUT_S:-3600}" --artifact artifacts/ios-sim/evidence.zip \
    --arg shots --arg statusbar=clean --arg "device=${model// /,}" "${scene_args[@]}" 2>&1 | tee "$log" || status=$?
  step=$(grep -o -E 'step [0-9a-f]{24}' "$log" | head -1 | cut -d' ' -f2 || true)
  [ -n "$step" ] || { echo "fleet: no step id in the client's output (exit $status)" >&2; exit 1; }
  "$client" artifact "$step" "$scratch/evidence.zip" || "$client" artifact --failed "$step" "$scratch/evidence.zip" ||
    { echo "fleet: step $step (exit $status) returned no artifact" >&2; exit 1; }
  unzip -oq "$scratch/evidence.zip" -d "$scratch/x"
  shots_dir=$(find "$scratch/x" -type d -name screens | head -1)
  [ -n "$shots_dir" ] || { echo "fleet: step $step's artifact has no screens/" >&2; exit 1; }
  cp "$shots_dir"/*.png "$out/"
  summary=$(find "$scratch/x" -name SUMMARY.md | head -1)
  [ -z "$summary" ] || cp "$summary" "$out/SUMMARY.md"
  rm -rf "$scratch"
  write_meta
  missing=0
  while IFS=$'\t' read -r name _ _; do
    [ -f "$out/$name.png" ] || { echo "$name: no screenshot from step $step" >&2; missing=$((missing + 1)); }
  done < <(rows)
  [ "$status" = 0 ] || { echo "fleet: step $step exited $status" >&2; exit 1; }
  [ "$missing" = 0 ] || { echo "$missing screen(s) missing" >&2; exit 1; }
  exit 0
fi

app=$target
bundle=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1] + "/Info.plist","rb"))["CFBundleIdentifier"])' "$app")
args=(-cmuxMobile.setupComplete YES -cmux-mobile-no-restore)

case "$backend" in
  simctl)
    udid=${SIM_UDID:-booted}
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100 || true
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
  for _ in $(seq 1 "$tries"); do
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
done < <(rows)
stop

write_meta
[ "$failed" = 0 ] || { echo "$failed screen(s) failed" >&2; exit 1; }
