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
--watch uses fswatch to restart the host after source saves.
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
    swift run --package-path "$package" -- --attach "$attach" &
  else
    swift run --package-path "$package" -- --snapshot "$snapshot" &
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

if (( ! watch )); then
  run_host
  wait_host
  exit $?
fi

if ! command -v fswatch >/dev/null 2>&1; then
  echo "--watch requires fswatch; install it or omit --watch" >&2
  exit 2
fi

host_pid=0
stop_host() {
  if ((host_pid > 0)) && kill -0 "$host_pid" 2>/dev/null; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
}
trap stop_host EXIT INT TERM
run_host
while IFS= read -r -d '' changed; do
  stop_host
  now="$(timestamp_ns)"
  echo "ui-layer.reload path=$changed requested_at_ns=$now" >&2
  run_host
done < <(fswatch -0 "$package/Package.swift" "$package/Sources")
wait_host || true
