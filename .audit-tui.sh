#!/usr/bin/env bash
OUT=${FAST_CHECKS_OUT:-/tmp/audit-out}; mkdir -p "$OUT/help"; cd "$OUT"
B=https://files.cmux.com/cmux-tui/dacb842785d4f573c5a0ff35def9148481a32277
[ -x ./cmux ] || { curl -fsSL -A cmux-cli -o cmux "$B/cmux-tui-x86_64-unknown-linux-gnu" || curl -fsSL -A cmux-cli -o cmux "$B/cmux-tui-x86_64-unknown-linux-musl"; chmod +x cmux; }
export HOME=${HOME:-/tmp}; export XDG_RUNTIME_DIR=$OUT/xdg; mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR
LOG=$OUT/log.jsonl; : > $LOG
S=(--session audit)
# run LABEL ARGS... : run cmux with timeout, log
run(){ local label=$1; shift
  timeout 90 ./cmux "$@" >$OUT/.o 2>$OUT/.e </dev/null; local rc=$?
  python3 - "$label" "$rc" "$*" <<'PY' >>$LOG
import json,sys
o=open('.o',errors='replace').read(); e=open('.e',errors='replace').read()
print(json.dumps({"label":sys.argv[1],"rc":int(sys.argv[2]),"cmd":"cmux "+sys.argv[3],"stdout":o[:5000],"stderr":e[:2500]}))
PY
  LASTRC=$rc; LASTO=$(cat $OUT/.o); LASTE=$(cat $OUT/.e)
}
id(){ echo "$LASTO" | grep -oE "$1_[0-9a-f]{8,}" | head -${2:-1} | tail -1; }
jvalid(){ python3 -c 'import json,sys;json.loads(sys.stdin.read());print("valid")' <<<"$LASTO" 2>/dev/null || echo "NOT-JSON"; }
note(){ python3 -c 'import json,sys;print(json.dumps({"label":"NOTE","msg":sys.argv[1]}))' "$1" >>$LOG; }
./cmux --version >$OUT/version.txt 2>&1
# help dumps
for s in daemon workspace screen pane tab terminal notification agent closed history session client attention status git space room settings browser; do ./cmux $s --help >help/$s.txt 2>&1; done
./cmux daemon --help > help/daemon.txt 2>&1


run daemon-ensure "${S[@]}" --json daemon ensure
run ws-create "${S[@]}" --json workspace create --name delta
WB=$(id ws); TA=$(id term); PA=$(id pane)
cat > $OUT/fail.sh <<'EOT'
echo failing-out; exit 7
EOT
cat > $OUT/slow.sh <<'EOT'
sleep 2; echo slow-done; exit 5
EOT
chmod +x $OUT/*.sh
note "WB=$WB TA=$TA PA=$PA"
run split "${S[@]}" --json pane $PA split --right
TB=$(id term); PB=$(id pane)
note "TB=$TB PB=$PB"
# T3
run run-ok "${S[@]}" --json terminal $TB run --timeout 20s -- echo hello-world
run run-fail "${S[@]}" --json terminal $TB run --timeout 20s -- bash $OUT/fail.sh
run run-nonexistent-cmd "${S[@]}" --json terminal $TB run --timeout 20s -- no_such_cmd_xyz
run run-quoting-sh-c "${S[@]}" --json terminal $TB run --timeout 20s -- sh -c 'echo a b; echo "c  d"'
run term-list-after "${S[@]}" --json terminal list
run send-prompt "${S[@]}" --json terminal $TB send --text 'echo via-send; sleep 1' --wait prompt --timeout 20s
run send-pattern "${S[@]}" --json terminal $TB send --text 'sleep 1; echo READY-XYZ' --pattern 'READY-XYZ' --timeout 20s
run send-exitstatus "${S[@]}" --json terminal $TB send --text 'false' --wait prompt --exit-with-status --timeout 20s
run send-none "${S[@]}" --json terminal $TB send --text 'sleep 2; echo LATE-OUT' --wait none
run screen-wait-new "${S[@]}" --json terminal $TB screen wait --pattern LATE-OUT --new --timeout-ms 15000
run screen-wait-timeout "${S[@]}" --json terminal $TB screen wait --pattern NEVER-APPEARS --timeout-ms 1500
run wait-idle "${S[@]}" --json terminal $TB wait --until idle --timeout 5s
run wait-prompt "${S[@]}" --json terminal $TB wait --until prompt --timeout 5s
run send-sleep-then-wait-timeout "${S[@]}" --json terminal $TB send --text 'sleep 8' --wait prompt --timeout 2s
run wait-prompt-timeout "${S[@]}" --json terminal $TB wait --until prompt --timeout 1s
run keys-ctrlc "${S[@]}" --json terminal $TB keys ctrl+c
run wait-prompt-after-ctrlc "${S[@]}" --json terminal $TB wait --until prompt --timeout 5s
run bad-regex "${S[@]}" --json terminal $TB screen wait --pattern '(' --timeout-ms 500
# process exit
run pane-run-keep "${S[@]}" --json pane $PB run --on-exit keep -- bash $OUT/slow.sh
TP=$(id term); note "TP=$TP"
run proc-show "${S[@]}" --json terminal $TP process show
run proc-wait-timeout "${S[@]}" --json terminal $TP process wait --timeout-ms 500
run proc-wait "${S[@]}" --json terminal $TP process wait --timeout-ms 20000
run proc-show-after "${S[@]}" --json terminal $TP process show
run proc-status "${S[@]}" --json terminal $TP status
run tab-create-run "${S[@]}" --json tab create terminal --workspace $WB -- bash $OUT/fail.sh
TQ=$(id term)
run proc-wait-fail "${S[@]}" --json terminal $TQ process wait --timeout-ms 20000
run proc-wait-closed-term "${S[@]}" --json terminal $TQ process wait --timeout-ms 1000
# T4
run screen-read "${S[@]}" --json terminal $TB screen read
run screen-read-lines "${S[@]}" --json terminal $TB screen read --lines 30 --unwrap
run screen-read-nojson "${S[@]}" terminal $TB screen read
run history-read "${S[@]}" --json terminal $TB history read --limit 20
run history-read-nolimit "${S[@]}" --json terminal $TB history read
run output-read "${S[@]}" --json terminal $TB output read --max-bytes 300
run output-read-after "${S[@]}" --json terminal $TB output read --after 100 --max-bytes 100
run copy "${S[@]}" --json terminal $TB copy --mode scrollback
run term-show "${S[@]}" --json terminal $TB show
run term-state "${S[@]}" --json terminal $TB state read
# errors on closed terminal / events
run close-pane-B "${S[@]}" --json pane $PB close
run err-closed-term-read "${S[@]}" --json terminal $TB screen read
run err-closed-term-send "${S[@]}" --json terminal $TB send --text hi --wait none
run err-ambiguous-name "${S[@]}" --json workspace delta rename delta
run events-jsonl "${S[@]}" --jsonl session current events
run jsonl-timeout-check "${S[@]}" --jsonl terminal $TA screen wait --pattern zzz --timeout-ms 800
run list-jsonl "${S[@]}" --jsonl workspace list
run ws-list-quiet "${S[@]}" --quiet workspace list
run ws-create-dup "${S[@]}" --json workspace create --name delta
run ws-list-dup "${S[@]}" --json workspace list
run ws-show-dup-byname "${S[@]}" --json workspace name:delta show
run ws-create-expected-rev "${S[@]}" --json workspace create --name eps --expected-revision 1
run agent-report "${S[@]}" --json agent report --terminal $TA --state working --source audit
run agent-list-after-report "${S[@]}" --json agent list
run agent-state-idle "${S[@]}" --json agent report --terminal $TA --state idle --source audit
run send-wait-idle-agent "${S[@]}" --json terminal $TA send --text 'echo agentish' --wait idle --timeout 10s --settle 1s
run term-list-agents "${S[@]}" --json terminal list --agents
run daemon-stop "${S[@]}" --json daemon stop
