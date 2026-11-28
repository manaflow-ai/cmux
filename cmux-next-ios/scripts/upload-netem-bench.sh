#!/usr/bin/env bash
# Attachment-upload bench over the real Rust link under degraded networks (Linux, sudo, tc netem).
#   upload-netem-bench.sh [--engine current|new] [--sizes "10 100 400"] [--profiles "none lte lossy-3 link-drop"]
#       [--loads "idle duress"] [--runs 5] [--runs-big 5] [--big-mb 400] [--big-profiles "..."] [--lanes 3]
#       [--transport wireguard|webrtc] [--cap 1200] [--csv FILE] [--quick]
# Runs tests/upload_netem.rs (one #[ignore]d cell per process). Each lane is its own netns + veth pair
# (10.77.<20+lane>.0/24) shaped with netem on both ends, with a real hostd inside; `lo` and the VM's
# NIC are never shaped. Namespaces are removed on exit. --quick: 1 run of 10 MB, to smoke the rig.
# Profiles: lte and lossy-3 read cmux-tui/crates/cmux-fault/link-profiles.json; link-drop is lte plus
# 100% loss for 20 s from 40% of the bytes (defined in the test).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rust=$here/../rust
engine=current sizes="10 100 400" profiles="none lte lossy-3 link-drop" loads="idle duress"
runs=5 runs_big=5 big_mb=400 big_profiles="" lanes=3 transport=wireguard cap=1200
out=${NETEM_OUT:-$HOME/notes/ios-attachment-send}
csv=""
while [ $# -gt 0 ]; do case $1 in
  --engine) engine=$2; shift 2;; --sizes) sizes=$2; shift 2;; --profiles) profiles=$2; shift 2;;
  --loads) loads=$2; shift 2;; --runs) runs=$2; shift 2;; --runs-big) runs_big=$2; shift 2;;
  --big-mb) big_mb=$2; shift 2;; --big-profiles) big_profiles=$2; shift 2;; --lanes) lanes=$2; shift 2;;
  --transport) transport=$2; shift 2;; --cap) cap=$2; shift 2;; --csv) csv=$2; shift 2;;
  --quick) sizes=10 runs=1 profiles="none lte" loads=idle; shift;;
  *) echo "unknown $1" >&2; exit 2;; esac; done
[ -n "$big_profiles" ] || big_profiles=$profiles
mkdir -p "$out"; [ -n "$csv" ] || csv=$out/runs-$engine-$transport.csv
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$HOME/.cache/cargo-target-ios-attach-bench}
exe=$(cd "$rust" && cargo test --release -p cmux-mobile-link-ffi --test upload_netem --no-run 2>&1 | tee /dev/stderr | sed -n 's/.*Executable .*(\(.*\))/\1/p' | tail -1)
[ -x "$exe" ] || { echo "no test binary" >&2; exit 1; }
header="engine,transport,profile,load,size_mb,run,connect_ms,open_ms,last_byte_ms,reply_ms,total_ms,bytes_sent,finished,code,max_stall_ms,capped"
[ -s "$csv" ] || echo "$header" > "$csv"

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/cmux-netem.XXXXXXXX") || exit 1
run_key=${run_dir##*.}
owned_namespaces=() owned_links=() owned_files=()
ns() { echo "iab${run_key}-$1"; }
host_if() { echo "va${run_key}$1"; }
peer_if() { echo "vb${run_key}$1"; }
cleanup() {
  for item in "${owned_namespaces[@]}"; do sudo -n ip netns del "$item" 2>/dev/null || true; done
  for item in "${owned_links[@]}"; do sudo -n ip link del "$item" 2>/dev/null || true; done
  for item in "${owned_files[@]}"; do rm -f -- "$item"; done
  rmdir -- "$run_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for l in $(seq 0 $((lanes-1))); do
  n=$(ns "$l"); host=$(host_if "$l"); peer=$(peer_if "$l"); sub=10.77.$((20+l))
  sudo -n ip netns add "$n" || exit 1
  owned_namespaces+=("$n")
  sudo -n ip link add "$host" type veth peer name "$peer" netns "$n" || exit 1
  owned_links+=("$host")
  sudo -n ip addr add $sub.1/24 dev "$host"; sudo -n ip link set "$host" up
  sudo -n ip netns exec "$n" ip addr add $sub.2/24 dev "$peer"
  sudo -n ip netns exec "$n" ip link set "$peer" up; sudo -n ip netns exec "$n" ip link set lo up
done

cells=$run_dir/cells  # lines: load size profile run
owned_files+=("$cells")
for load in $loads; do for size in $sizes; do
  if [ "$size" -ge "$big_mb" ]; then ps=$big_profiles; r=$runs_big; else ps=$profiles; r=$runs; fi
  for p in $ps; do for i in $(seq 1 "$r"); do echo "$load $size $p $i"; done; done
done; done > "$cells"

lane_loop() {  # lane load file
  local l=$1 load=$2 file=$3 k=0 line
  while read -r line <&3; do
    k=$((k+1)); [ $(( (k-1) % lanes )) -eq "$l" ] || continue
    set -- $line
    sudo -n tc qdisc del dev "$(host_if "$l")" root 2>/dev/null; sudo -n ip netns exec "$(ns "$l")" tc qdisc del dev "$(peer_if "$l")" root 2>/dev/null
    echo "[lane $l] $line" >&2
    NETEM_NS=$(ns "$l") NETEM_HOST_IF=$(host_if "$l") NETEM_NS_IF=$(peer_if "$l") NETEM_HOST_IP=10.77.$((20+l)).1 \
    NETEM_SIZE_MB=$2 NETEM_PROFILE=$3 NETEM_LOAD=$1 NETEM_RUN=$4 NETEM_TRANSPORT=$transport \
    NETEM_ENGINE=$engine NETEM_CAP_SECS=$cap NETEM_CSV=$csv USER=${USER:-$(id -un)} \
      "$exe" --exact upload_netem_cell --ignored --nocapture --test-threads=1 2>&1 | grep -E 'HANG|link-drop|relink|stage|NETEM-ROW|panicked' | sed "s/^/[lane $l] /" >&2
  done 3< "$file"
}
for load in $loads; do
  owned_files+=("$cells.$load")
  grep "^$load " "$cells" > "$cells.$load"
  pids=""
  for l in $(seq 0 $((lanes-1))); do lane_loop "$l" "$load" "$cells.$load" & pids="$pids $!"; done
  wait $pids
done
python3 -I "$here/upload-netem-summary.py" "$csv" > "$out/baseline-$engine-$transport.md" && echo "wrote $out/baseline-$engine-$transport.md"
