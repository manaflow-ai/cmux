#!/usr/bin/env bash
# A/B: rust-live's one-line core edit, timed per crate, under several dev-profile variants (cargo --config), one job.
# Usage: bash .dlc-ab.sh VARIANT... ; a variant is NAME or NAME=cfg1,cfg2 (cargo --config values, ';' joins).
set -uo pipefail
cd cmux-tui; TIME_PASSES=${TIME_PASSES:-1}
export CARGO_TERM_COLOR=never
nproc; rustc -V; env | grep -E "^(CARGO|RUSTC|RUSTFLAGS)" | sort
F=crates/cmux-tui-core/src/server/cmd_server.rs
TP=$PWD/../.dlc-tp2.sh
edit() {
  git checkout -q -- "$F"
  TOK=$1 python3 - <<'PY'
import os,importlib.util,sys
spec=importlib.util.spec_from_file_location("rl","../scripts/cmux-next/rust-live.py");rl=importlib.util.module_from_spec(spec);sys.modules["rl"]=rl;spec.loader.exec_module(rl)
p="crates/cmux-tui-core/src/server/cmd_server.rs";s=open(p).read();assert rl.EDIT_ANCHOR in s
open(p,"w").write(s.replace(rl.EDIT_ANCHOR, rl.EDIT_ANCHOR+'        "live_probe": "%s",\n'%os.environ["TOK"],1))
PY
}
summ() {
  H=$(ls -t ${CARGO_TARGET_DIR:-target}/cargo-timings/cargo-timing-*.html | head -1)
  python3 - "$H" <<'PY'
import re,sys,json
h=open(sys.argv[1]).read()
m=re.search(r'const UNIT_DATA = (\[.*?\]);',h,re.S)
for u in sorted(json.loads(m.group(1)),key=lambda u:-u["duration"])[:6]:
    print(f'  {u["name"]:24} {u.get("target",""):14} start {u["start"]:6.2f} dur {u["duration"]:6.2f} rmeta {u.get("rmeta_time")}')
PY
}
for v in "$@"; do
  name=${v%%=*}; cfgs=(); if [ "$v" != "$name" ]; then IFS=';' read -ra cs <<<"${v#*=}"; for c in "${cs[@]}"; do cfgs+=(--config "$c"); done; fi
  echo "##### variant $name ${cfgs[*]:-}"
  git checkout -q -- "$F"
  unset RUSTC_WRAPPER
  t0=$(date +%s); timeout 1500 cargo build --profile dev -p cmux-tui --bin cmux-tui -q "${cfgs[@]}" 2>&1 | grep -E '^error' | head -5; echo "warm_s=$(( $(date +%s)-t0 ))"
  for tok in a1 a2 a3; do
    edit "$name$tok"
    if [ "$tok" = a3 ] && [ -n "${TIME_PASSES:-}" ]; then export RUSTC_WRAPPER=$TP; rm -f /tmp/tp-*.txt; fi
    t0=$(date +%s.%N); timeout 600 cargo build --profile dev -p cmux-tui --bin cmux-tui --timings -q "${cfgs[@]}" 2>&1 | grep -E '^error' | head -5
    echo "RESULT $name $tok edit_s=$(echo "$(date +%s.%N)-$t0"|bc)"
    summ
  done
  if [ -n "${TIME_PASSES:-}" ]; then for f in /tmp/tp-*.txt; do echo "--- $name $f"; grep -E "^time:" "$f" | sort -k2 -g -r | head -30; grep -iE "incremental|cgu|reus" "$f" | head -20; done; fi
done
git checkout -q -- "$F"
