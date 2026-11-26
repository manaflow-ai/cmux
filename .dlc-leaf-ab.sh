#!/usr/bin/env bash
# TEMPORARY (removed before landing): A/B for goal dev-loop-ceiling idea c on one host, one warm tree.
# A = the old edit set: a one-line edit in cmux-tui-core's server (cmd_server.rs) reruns core, the
#     cmux-tui lib and the bin, exactly what rust-live's identify edit reran before this change.
# B = rust-live's identify edit now (cmux-tui/src/bin/cmux-tui/identify.rs): the bin crate + link.
set -uo pipefail
# The worker's checkout leaves submodules empty; ghostty-vt-sys builds from ghostty-next.
git submodule update --init --depth 1 ghostty-next || exit 1
test -f ghostty-next/build.zig || { echo "ghostty-next still empty"; exit 1; }
cd cmux-tui
step() { # $1 label, rest: cargo args; fails the run on a failed step
  echo "=== $1"; cargo "${@:2}" --message-format=short > /tmp/dlc-step.log 2>&1; rc=$?
  grep -E "^(error|crates/[^ ]*: error)|^test result|Finished" /tmp/dlc-step.log | head -40
  [ $rc -eq 0 ] || { echo "STEP $1 FAILED rc=$rc"; tail -40 /tmp/dlc-step.log; exit 1; }
}
step check-bin check -p cmux-tui --bin cmux-tui
step check-tests check -p cmux-tui-core -p cmux-tui --tests
step check-hotpatch check -p cmux-tui --features hotpatch --bin cmux-tui-hotpatch
echo "=== test-identify"; cargo test -p cmux-tui-core --lib identify 2>&1 | grep -E "^test result|FAILED|panicked" ; [ ${PIPESTATUS[0]} -eq 0 ] || { echo "STEP test-identify FAILED"; exit 1; }
export CARGO_TERM_COLOR=never
unset RUSTC_WRAPPER
N="${N:-4}"
nproc; uptime; rustc -V; cargo -V
t0=$(date +%s); cargo build --profile dev -p cmux-tui --bin cmux-tui -q 2>&1 | tail -5; [ ${PIPESTATUS[0]} -eq 0 ] || { echo "warm build FAILED"; exit 1; }; echo "warm_s=$(( $(date +%s)-t0 ))"
A=crates/cmux-tui-core/src/server/cmd_server.rs
B=crates/cmux-tui/src/bin/cmux-tui/identify.rs
timings() {
  H=$(ls -t ${CARGO_TARGET_DIR:-target}/cargo-timings/cargo-timing-*.html | head -1)
  python3 - "$H" <<'PY'
import re,sys,json
h=open(sys.argv[1]).read()
m=re.search(r'const UNIT_DATA = (\[.*?\]);',h,re.S)
for u in sorted(json.loads(m.group(1)),key=lambda u:-u["duration"])[:6]:
    print(f'  unit {u["name"]:28} {u.get("target",""):14} dur {u["duration"]:7.2f}')
PY
}
round() { # $1 label, $2 file, $3 anchor, $4 inserted line
  git checkout -q -- "$A" "$B"
  F="$2" ANCHOR="$3" LINE="$4" python3 - <<'PY'
import os
p,a,l=os.environ["F"],os.environ["ANCHOR"],os.environ["LINE"]
s=open(p).read(); assert a in s,(p,a)
open(p,"w").write(s.replace(a,a+l,1))
PY
  t0=$(date +%s.%N)
  cargo build --profile dev -p cmux-tui --bin cmux-tui --timings -q > /tmp/dlc-round.log 2>&1 || { echo "ROUND $1 BUILD FAILED"; tail -30 /tmp/dlc-round.log; exit 1; }
  echo "RESULT $1 edit_s=$(echo "$(date +%s.%N)-$t0" | bc) load=$(cut -d' ' -f1 /proc/loadavg)"
  timings
}
for i in $(seq 1 "$N"); do
  round A "$A" '        "ok": true,'$'\n' "        \"ab_probe\": $i,"$'\n'
  round B "$B" '        "daemon_handoff": 1,'$'\n' "        \"ab_probe\": $i,"$'\n'
done
git checkout -q -- "$A" "$B"
cargo build --profile dev -p cmux-tui --bin cmux-tui -q 2>&1 | tail -3
