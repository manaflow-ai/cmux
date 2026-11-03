#!/usr/bin/env bash
set -euo pipefail

# Debug-only warm host. It consumes a copied/exported projection and never
# sends commands to cmuxd or mutates the running app's state.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Prototypes/UiLayerHost"
snapshot="${CMUX_UI_LAYER_SNAPSHOT:-${TMPDIR:-/tmp}/cmux-ui-layer.json}"
snapshot_explicit=0
if [[ -n "${CMUX_UI_LAYER_SNAPSHOT:-}" ]]; then snapshot_explicit=1; fi
attach=""
watch=0

timestamp_ns() {
  # Timing is opt-in so the normal host launch has no Python dependency.
  if [[ "${CMUX_UI_LAYER_TRACE:-0}" != 1 ]]; then
    printf '0\n'
    return 0
  fi
  # macOS date lacks GNU %N; Python provides a monotonic trace clock.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "CMUX_UI_LAYER_TRACE=1 requires python3 for monotonic timing" >&2
    return 2
  fi
  python3 -c 'import time; print(time.monotonic_ns())'
}

usage() {
  cat <<'EOF'
Usage: Prototypes/UiLayerHost/launch.sh [--snapshot PATH | --attach SOCKET] [--watch]

Launches the Debug UI-layer host against a read-only JSON projection or an
explicit cmux NEXT control socket. --attach establishes events.stream first,
then reads system.identify and snapshot.get; it never sends mutation verbs.
--watch uses the checked-in Swift vnode watcher to restart the host after
source saves with no third-party watcher dependency.
EOF
}

while (($#)); do
  case "$1" in
    --snapshot)
      [[ $# -ge 2 ]] || { echo "--snapshot needs a path" >&2; exit 2; }
      [[ -z "$attach" ]] || { echo "use exactly one of --attach or --snapshot" >&2; exit 2; }
      snapshot="$2"; snapshot_explicit=1; shift 2 ;;
    --attach)
      [[ $# -ge 2 ]] || { echo "--attach needs a socket path" >&2; exit 2; }
      [[ -z "$attach" && $snapshot_explicit -eq 0 ]] || { echo "use exactly one of --attach or --snapshot" >&2; exit 2; }
      attach="$2"; shift 2 ;;
    --watch) watch=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$attach" ]]; then
  [[ -S "$attach" ]] || { echo "cmux NEXT socket does not exist: $attach" >&2; exit 1; }
fi

if [[ ! -f "$snapshot" ]]; then
  if ((snapshot_explicit)); then
    echo "snapshot does not exist: $snapshot" >&2
    exit 1
  fi
  snapshot="$package/Resources/cmux-ui-layer.example.json"
fi

run_host() {
  host_started="$(timestamp_ns)"
  if [[ -n "$attach" ]]; then
    swift run --package-path "$package" cmux-ui-layer --attach "$attach" &
  else
    swift run --package-path "$package" cmux-ui-layer --snapshot "$snapshot" &
  fi
  host_pid=$!
}

wait_host() {
  local status finished
  if wait "$host_pid"; then status=0; else status=$?; fi
  finished="$(timestamp_ns)"
  if [[ "${CMUX_UI_LAYER_TRACE:-0}" == 1 ]]; then
    echo "ui-layer.host_exit elapsed_ms=$(( (finished - host_started) / 1000000 )) status=$status" >&2
  fi
  return "$status"
}

if (( watch )); then
  watch_args=(--package "$package")
  # Follow the host and the real leaf modules it imports. A save in one of
  # these modules must restart the host; the running cmux app is untouched.
  watch_args+=(--watch-root "$package/Sources/UiLayerHost")
  watch_args+=(--watch-root "$root/Packages/macOS/CmuxNext/Sources/CmuxNextUiLayerPreview")
  watch_args+=(--watch-root "$root/Packages/macOS/CmuxNext/Sources/CmuxNextDesign")
  watch_args+=(--watch-root "$root/Packages/macOS/CmuxNext/Sources/CmuxNextIcons")
  if [[ -n "$attach" ]]; then
    watch_args+=(--attach "$attach")
  else
    watch_args+=(--snapshot "$snapshot")
  fi
  exec swift run --package-path "$package" cmux-ui-layer-watch -- "${watch_args[@]}"
fi

if (( ! watch )); then
  run_host
  wait_host
  exit $?
fi
