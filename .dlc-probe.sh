#!/usr/bin/env bash
# Warm dev build of cmux-tui's daemon bin, then rust-live's one-line edit in core, timed per crate.
set -uo pipefail
cd cmux-tui
export CARGO_TERM_COLOR=never
unset RUSTC_WRAPPER
nproc; rustc -V; cargo -V
t0=$(date +%s); cargo build --profile dev -p cmux-tui --bin cmux-tui -q 2>&1 | tail -5; echo "warm_s=$(( $(date +%s)-t0 ))"
export RUSTC_WRAPPER=$PWD/../.dlc-tp.sh
for tok in p1 p2 p3; do
rm -f /tmp/tp-*.txt
echo "=== round $tok"
git checkout -q -- crates/cmux-tui-core/src/server/cmd_server.rs
F=crates/cmux-tui-core/src/server/cmd_server.rs
TOK=$tok python3 - <<'PY'
import re,sys
sys.path.insert(0,"../scripts/cmux-next")
import importlib.util
spec=importlib.util.spec_from_file_location("rl","../scripts/cmux-next/rust-live.py");rl=importlib.util.module_from_spec(spec);sys.modules["rl"]=rl;spec.loader.exec_module(rl)
p="crates/cmux-tui-core/src/server/cmd_server.rs";s=open(p).read();assert rl.EDIT_ANCHOR in s
import os
open(p,"w").write(s.replace(rl.EDIT_ANCHOR, rl.EDIT_ANCHOR+'        "live_probe": "%s",\n'%os.environ["TOK"],1))
PY
t0=$(date +%s.%N); cargo build --profile dev -p cmux-tui --bin cmux-tui --timings -v 2>&1 | grep -E 'Running|Fresh|Compiling|Finished' | grep -vE '^\s*Fresh' | sed -E 's/--cfg [^ ]+//g' | cut -c1-300 | tail -30; echo "edit_s=$(echo "$(date +%s.%N)-$t0"|bc)"
H=$(ls -t ${CARGO_TARGET_DIR:-target}/cargo-timings/cargo-timing-*.html | head -1)
python3 - "$H" <<'PY'
import re,sys,json
h=open(sys.argv[1]).read()
m=re.search(r'const UNIT_DATA = (\[.*?\]);',h,re.S)
for u in sorted(json.loads(m.group(1)),key=lambda u:-u["duration"])[:15]:
    print(f'{u["name"]:40} {u.get("target",""):12} start {u["start"]:7.2f} dur {u["duration"]:7.2f} rmeta {u.get("rmeta_time")}')
PY
for f in /tmp/tp-*.txt; do echo "--- $f"; grep -E "^time:" "$f" | sort -k2 -g -r | head -30; done
done
