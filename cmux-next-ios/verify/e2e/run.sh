#!/usr/bin/env bash
# cmux-next-ios end-to-end rig. Re-runnable after merges.
#
#   run.sh fetch-mac REF        fleet-build REF (a pushed sha of a branch with the
#                               Mac integration, e.g. origin/feat-cnx-ios-machost),
#                               tag cmux-mobile-e2e-<sha8>, into ~/cmux-mobile-builds/<date>-<sha10>-e2e/
#   run.sh [e2e.py options]     run: real tagged Mac app (hidden, isolated config,
#                               dev sign-in) + iOS app (Demo config) in ONE headless
#                               simulator; journey + latency; quits the Mac app and
#                               deletes the simulator at the end (unless --keep)
#   run.sh both                 iOS 26.5 pass, then iOS 27 pass (sequential)
#
# e2e.py options: --mac-app PATH --ios 26|27 --config Demo|Debug --no-build
#   --steps a,b --skip a,b --latency all|none|keystroke_echo_idle,... --samples N --keep
# Evidence: cmux-next-ios/verify/evidence/<date>/e2e/<HHMMSS>-ios<NN>/ (results.json,
# run.log, shots/, latency/*.mp4). Never opens Simulator.app; never touches the
# user's cmux apps (own bundle id, socket, settings file, keychain items).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

case "${1:-}" in
  fetch-mac)
    ref=${2:?usage: run.sh fetch-mac REF}
    repo="$(cd "$here/../../.." && pwd)"
    git -C "$repo" fetch -q origin
    sha=$(git -C "$repo" rev-parse "$ref")
    tag="cmux-mobile-e2e-${sha:0:8}"
    dest="$HOME/cmux-mobile-builds/$(date -u +%Y%m%d)-${sha:0:10}-e2e"
    src="/tmp/cmux-mobile-e2e-src-${sha:0:8}"
    [[ -d "$src" ]] || git -C "$repo" worktree add -q --detach "$src" "$sha"
    mkdir -p "$dest"
    hq="${HQ_ROOT:-$(cd "$repo/../.." && pwd)}"
    job=$(cd "$src" && ~/.local/bin/cmux-ci build cmux --ref "$sha" --tag "$tag" --priority -10 \
          --workspace "${E2E_PR_URL:-https://github.com/manaflow-ai/cmux/pull/20414}" \
          --backend-helper "$hq/scripts/dev-backend.sh" --receipt "$dest/submit.json" | tee "$dest/submit.log" \
          | python3 -c 'import json,sys; print([json.loads(l) for l in sys.stdin if l.startswith("{")][-1]["id"])')
    echo "fleet job $job ($tag); waiting"
    ~/.local/bin/cmux-ci wait "$job" --receipt "$dest/terminal.json" || { echo "wait again: ~/.local/bin/cmux-ci wait $job (never resubmit)"; exit 1; }
    ~/.local/bin/cmux-ci artifact "$job" "$dest/cmux.app.zip"
    rm -rf "$dest/app"; mkdir -p "$dest/app"; ditto -x -k "$dest/cmux.app.zip" "$dest/app"
    echo "$ref $sha; fleet job $job, tag $tag" > "$dest/SOURCE"
    git -C "$repo" worktree remove --force "$src" || true
    ls -d "$dest"/app/*.app
    ;;
  both)
    shift
    python3 "$here/e2e.py" --ios 26 "$@"
    python3 "$here/e2e.py" --ios 27 --no-build "$@"
    ;;
  *)
    exec python3 "$here/e2e.py" "$@"
    ;;
esac
