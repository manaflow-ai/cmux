#!/usr/bin/env bash
# One stress-loop run as a fleet step (class simulator, a mini with a GUI session):
#
#   cmux-ci run --class simulator --script cmux-next-ios/verify/stress/fleet-step.sh --ref SHA \
#     --arg mac_job=JOB --arg ios_job=JOB [--arg cycles=N] [--arg start=N] [--arg add=N] [--arg max=N] \
#     [--arg feed=S] [--arg paths=a,b] --artifact artifacts/stress/evidence.zip --timeout 7200
#
# mac_job: a done `cmux-ci build cmux` job (the tagged cmux NEXT Mac app).
# ios_job: a done `cmux-next-ios-sim.sh build` step (its evidence.zip holds the
#          Demo iPhone app for the simulator).
# Codex comes from npm into the step folder and reaches its model through the
# worker's ~/.codex/config.toml (the fleet's subrouter). Everything the run
# writes is in artifacts/stress/ (stress.py's evidence plus report.html),
# zipped to artifacts/stress/evidence.zip. The rig's simulator is deleted and
# its Mac app quit at the end.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
mac_job="" ios_job="" cycles=4 start=4 add=4 max=40 feed=4 paths=""
for kv in "$@"; do
  case "$kv" in
    mac_job=*) mac_job=${kv#*=} ;; ios_job=*) ios_job=${kv#*=} ;; cycles=*) cycles=${kv#*=} ;;
    start=*) start=${kv#*=} ;; add=*) add=${kv#*=} ;; max=*) max=${kv#*=} ;; feed=*) feed=${kv#*=} ;;
    paths=*) paths=${kv#*=} ;;
    *) echo "fleet-step.sh: unknown argument $kv" >&2; exit 2 ;;
  esac
done
[[ -n "$mac_job" && -n "$ios_job" ]] || { echo "fleet-step.sh: mac_job= and ios_job= are required" >&2; exit 2; }
art="$repo/artifacts/stress"
work="$repo/.stress-work"
rm -rf "$art" "$work"; mkdir -p "$art" "$work"
ci="$(command -v cmux-ci || echo "$HOME/.local/bin/cmux-ci")"

echo "== Mac app from fleet job $mac_job"
"$ci" artifact "$mac_job" "$work/cmux.app.zip"
mkdir -p "$work/mac/app"; ditto -x -k "$work/cmux.app.zip" "$work/mac/app"
mac_app="$(ls -d "$work"/mac/app/*.app | head -1)"
echo "== iPhone app from fleet step $ios_job"
"$ci" artifact "$ios_job" "$work/ios-evidence.zip"
mkdir -p "$work/ios"; ditto -x -k "$work/ios-evidence.zip" "$work/ios"
ios_zip="$(find "$work/ios" -name 'CmuxMobileApp-*-simulator.app.zip' | head -1)"
if [[ -n "$ios_zip" ]]; then mkdir -p "$work/ios/app"; ditto -x -k "$ios_zip" "$work/ios/app"; fi
ios_app="$(find "$work/ios" -type d -name 'CmuxMobileApp.app' | head -1)"
[[ -n "$ios_app" ]] || { echo "fleet-step.sh: no CmuxMobileApp.app in step $ios_job's artifact" >&2; find "$work/ios" -maxdepth 3 | head -40 >&2; exit 1; }

echo "== Codex CLI"
node_bin="$(dirname "$(command -v node 2>/dev/null || ls -d "$HOME"/.local/share/cmux-node/node-*/bin/node | tail -1)")"
PATH="$node_bin:$PATH" npm install -g --silent @openai/codex --prefix "$work/npm" >/dev/null
codex="$work/npm/bin/codex"
PATH="$node_bin:$PATH" "$codex" --version

echo "== stress loop: $cycles cycles, $start agents, +$add a cycle up to $max, a Feed event every ${feed}s"
rc=0
python3 "$here/stress.py" --mac-app "$mac_app" --ios-app "$ios_app" --codex "$codex" --node-bin "$node_bin" \
  --sim-name "cmux-stress-$(date +%H%M%S)" --cycles "$cycles" --start-agents "$start" --add-per-cycle "$add" \
  --max-agents "$max" --feed-interval "$feed" ${paths:+--paths "$paths"} --out "$art/run" || rc=$?
python3 "$here/render_report.py" --out "$art/report.html" "$art/run" || true
(cd "$art" && zip -qr evidence.zip run report.html) || true
echo "stress loop exit $rc; evidence artifacts/stress/evidence.zip"
exit "$rc"
