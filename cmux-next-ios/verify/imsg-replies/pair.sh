#!/bin/bash
# Paired reference (Messages + ReplyOn) and ours (Chief on conversation-sim)
# on two iPhone 17 Pro Max iOS 27.0 simulators. Source it.
# OUT=<dir> before sourcing; both <axe args> sends the same input to both.
source ~/imsgreply/udids
A=~/.local/bin/axe
export PATH=/opt/homebrew/bin:$PATH
mkdir -p "$OUT"
# Background processes these helpers start (recorders, gesture servers) record their PIDs in
# pidfiles here, and are stopped by those PIDs only: never by name, so another run's recorder or
# test runner on this Mac is left alone.
PIDDIR=$HOME/imsgreply/pids
mkdir -p "$PIDDIR"
# _pid_of FILE MATCH: the PID recorded in FILE, if that process still runs and its command line
# contains MATCH (a recycled PID is not ours).
_pid_of() { local p; p=$(cat "$1" 2>/dev/null) || return 1
  [ -n "$p" ] && ps -p "$p" -o command= 2>/dev/null | grep -qF -- "$2" && echo "$p"; }
# _pid_stop FILE MATCH [SIGNAL]: signal the recorded process and wait (up to 20 s) for it to exit.
_pid_stop() { local p i; p=$(_pid_of "$1" "$2") && { kill -"${3:-TERM}" "$p" 2>/dev/null
    for i in $(seq 1 100); do kill -0 "$p" 2>/dev/null || break; sleep 0.2; done; }
  rm -f "$1"; }
SIMCTL=$(xcrun -f simctl)
both() {
  $A "$@" --udid "$REF" >/dev/null 2>&1 & local a=$!
  $A "$@" --udid "$OURS" >/dev/null 2>&1 & wait $a $!
}
ref() { $A "$@" --udid "$REF" >/dev/null 2>&1; }
ours() { $A "$@" --udid "$OURS" >/dev/null 2>&1; }
shot() {
  xcrun simctl io "$REF" screenshot "$OUT/$1-ref.png" >/dev/null 2>&1 & local a=$!
  xcrun simctl io "$OURS" screenshot "$OUT/$1-ours.png" >/dev/null 2>&1 & wait $a $!
  ffmpeg -loglevel error -y -i "$OUT/$1-ref.png" -i "$OUT/$1-ours.png" -filter_complex "[0][1]hstack=inputs=2,scale=880:-1" "$OUT/$1-sbs.jpg"
}
rec_start() {
  REC=$1
  # A recorder left by an interrupted run holds the display ("Host recording is already in progress").
  _pid_stop "$PIDDIR/rec-$REF.pid" "recordVideo" INT; _pid_stop "$PIDDIR/rec-$OURS.pid" "recordVideo" INT
  for s in ref ours; do u=$REF; [ $s = ours ] && u=$OURS
    # simctl itself (not the xcrun shim), so the recorded PID is the recorder's.
    "$SIMCTL" io "$u" recordVideo --codec h264 --force "$OUT/$1-$s.mp4" >"$OUT/$1-$s.reclog" 2>&1 &
    echo $! > "$PIDDIR/rec-$u.pid"
  done
  for i in $(seq 1 100); do
    grep -q "Recording started" "$OUT/$1-ref.reclog" && grep -q "Recording started" "$OUT/$1-ours.reclog" && return 0
    grep -q -i "error" "$OUT/$1-ref.reclog" "$OUT/$1-ours.reclog" && break
    sleep 0.1
  done
  echo "rec_start $1 failed: $(cat $OUT/$1-*.reclog | grep -i error | head -1)" >&2
  return 1
}
rec_stop() {
  _pid_stop "$PIDDIR/rec-$REF.pid" "$OUT/$REC-" INT; _pid_stop "$PIDDIR/rec-$OURS.pid" "$OUT/$REC-" INT
  rm -f "$OUT/$REC"-*.reclog
  ffmpeg -loglevel error -y -i "$OUT/$REC-ref.mp4" -i "$OUT/$REC-ours.mp4" -filter_complex "[0]scale=440:-2,fps=30[a];[1]scale=440:-2,fps=30[b];[a][b]hstack=inputs=2" -c:v libx264 -pix_fmt yuv420p "$OUT/$REC-sbs.mp4"
}
# Frames (fps) of the last recording as one contact strip per side.
strip() {
  for s in ref ours; do
    ffmpeg -loglevel error -y -i "$OUT/$1-$s.mp4" -vf "fps=${2:-10},scale=147:-1,tile=${3:-12}x1" -frames:v 1 "$OUT/$1-$s-strip.jpg"
  done
}
# A finger drag as a run of touch-downs (one finger moving), then up.
# fdrag <udid> x0 y0 x1 y1 [steps] [stepSleep] [hold seconds at the end]
fdrag() {
  local u=$1 x0=$2 y0=$3 x1=$4 y1=$5 n=${6:-24} dt=${7:-0.012} hold=${8:-0} f i x y
  f=$(mktemp)
  for ((i=0; i<=n; i++)); do
    x=$(( x0 + (x1 - x0) * i / n )); y=$(( y0 + (y1 - y0) * i / n ))
    echo "touch -x $x -y $y --down" >> $f; echo "sleep $dt" >> $f
  done
  [ "$hold" != 0 ] && echo "sleep $hold" >> $f
  echo "touch -x $x1 -y $y1 --up" >> $f
  $A batch --udid "$u" --file $f >/dev/null 2>&1; rm -f $f
}
# Same drag on both (ref at y0r, ours at y0o).
bdrag() { fdrag $REF $1 $2 $3 $2 ${@:5} & local a=$!; fdrag $OURS $1 $4 $3 $4 ${@:5} & wait $a $!; }
# XCUITest gesture servers (GestureServerUITests), one per simulator.
# serve_start <products dir>: (re)starts both; then g ref|ours <cmd...>, gb <cmd...> (both at once).
GDIR=$HOME/imsgreply/gest
serve_start() {
  local dd=${1:-$HOME/imsgreply/dd-base}
  _pid_stop "$PIDDIR/gest-ref.pid" GestureServerUITests; _pid_stop "$PIDDIR/gest-ours.pid" GestureServerUITests; sleep 0.5
  for s in ref ours; do
    local u=$REF; [ $s = ours ] && u=$OURS
    rm -rf $GDIR/$s; mkdir -p $GDIR/$s; echo 0 > $GDIR/$s.n
    TEST_RUNNER_GESTURE_DIR=$GDIR/$s nohup xcodebuild test-without-building -xctestrun $(ls $dd/Build/Products/*.xctestrun | head -1) \
      -destination "id=$u" -only-testing:CmuxMobileAppUITests/GestureServerUITests/testServe -test-timeouts-enabled NO \
      > $GDIR/$s.log 2>&1 &
    echo $! > "$PIDDIR/gest-$s.pid"
  done
}
_bundle() { [ $1 = ref ] && echo com.apple.MobileSMS || echo dev.cmux.mobile; }
_gsend() { local s=$1; shift; local n=$(( $(cat $GDIR/$s.n) + 1 )); echo $n > $GDIR/$s.n
  local c=$1; shift; echo "$c $(_bundle $s) $*" > $GDIR/$s/$n.tmp; mv $GDIR/$s/$n.tmp $GDIR/$s/$n.cmd; echo $n; }
# Alive = its xcodebuild runs and the log has no end-of-run line after the last start.
_galive() { _pid_of "$PIDDIR/gest-$1.pid" GestureServerUITests >/dev/null || return 1
  ! tail -40 $GDIR/$1.log | grep -q -E "TEST EXECUTE FAILED|Executed 0 tests|Restarting after unexpected exit"; }
# Waits for one command; a dead or stuck runner (under host load) is restarted and the command resent once.
_gwait() { local s=$1 n=$2 i
  for i in $(seq 1 ${GTIMEOUT:-1200}); do [ -f $GDIR/$s/$n.done ] && return 0; [ $((i % 40)) = 0 ] && ! _galive $s && break; sleep 0.05; done
  [ -f $GDIR/$s/$n.done ] && return 0
  echo "gesture server $s: command $n ($(cat $GDIR/$s/$n.cmd)) did not finish; restarting" >&2
  local cmd=$(cat $GDIR/$s/$n.cmd); serve_one $s
  local m=$(( $(cat $GDIR/$s.n) + 1 )); echo $m > $GDIR/$s.n
  echo "$cmd" > $GDIR/$s/$m.tmp; mv $GDIR/$s/$m.tmp $GDIR/$s/$m.cmd
  for i in $(seq 1 ${GTIMEOUT:-1200}); do [ -f $GDIR/$s/$m.done ] && return 0; sleep 0.05; done
  echo "gesture server $s: retry $m failed too" >&2; return 1; }
g() { local s=$1; shift; local n=$(_gsend $s "$@"); _gwait $s $n; }
# gb <cmd> args-for-ref -- args-for-ours
gb() { local c=$1; shift; local ra=() oa=() side=r
  for a in "$@"; do if [ "$a" = -- ]; then side=o; elif [ $side = r ]; then ra+=("$a"); else oa+=("$a"); fi; done
  [ ${#oa[@]} = 0 ] && oa=("${ra[@]}")
  local nr=$(_gsend ref $c "${ra[@]}") no=$(_gsend ours $c "${oa[@]}"); _gwait ref $nr; _gwait ours $no; }
# Restart one side's gesture server (after its target app crashed).
serve_one() {
  local s=$1 dd=${2:-$HOME/imsgreply/dd-base} u=$REF
  [ $s = ours ] && u=$OURS
  _pid_stop "$PIDDIR/gest-$s.pid" GestureServerUITests; sleep 0.3
  rm -rf $GDIR/$s; mkdir -p $GDIR/$s; echo 0 > $GDIR/$s.n
  DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer TEST_RUNNER_GESTURE_DIR=$GDIR/$s nohup xcodebuild test-without-building -xctestrun $(ls $dd/Build/Products/*.xctestrun | head -1) \
    -destination "id=$u" -only-testing:CmuxMobileAppUITests/GestureServerUITests/testServe -test-timeouts-enabled NO > $GDIR/$s.log 2>&1 &
  echo $! > "$PIDDIR/gest-$s.pid"
  until grep -q "testServe\]' started" $GDIR/$s.log; do sleep 0.5; done; sleep 1.5
}

# Keyboard down on both: interactive dismiss until neither shows a keyboard.
kbvisible() { $A describe-ui --udid $1 2>/dev/null | grep -q '"AXLabel" : "shift"\|"AXLabel":"shift"\|"shift"'; }
kbdown_both() {
  for i in 1 2 3; do
    local any=0
    for s in ref ours; do local u=$REF; [ $s = ours ] && u=$OURS
      if kbvisible $u; then any=1; g $s drag 220 380 220 905 0.02 1200 0; fi
    done
    [ $any = 0 ] && return 0; sleep 0.8
  done
}

# Center (x y, points) of the first element whose label contains TEXT, or nothing.
# The smallest matching element wins: a row and its bubble share a label.
center_of() { $A describe-ui --udid $1 2>/dev/null | python3 -c '
import json,sys
t=sys.argv[1]; best=None
def walk(n):
  global best
  l=n.get("AXLabel") or ""; v=n.get("AXValue") or ""; f=n.get("frame")
  if (t in l or t in v) and f and f["width"] > 0 and f["height"] > 0:
    a=f["width"]*f["height"]
    if best is None or a < best[0]: best=(a, f)
  for c in n.get("children",[]): walk(c)
for n in json.load(sys.stdin): walk(n)
if best: f=best[1]; print(round(f["x"]+f["width"]/2), round(f["y"]+f["height"]/2))' "$2"; }
# Long-press TEXT on both sides, each at its own position.
press_text() { local r o; r=$(center_of $REF "$1"); o=$(center_of $OURS "$1")
  [ -n "$r" ] && $A touch -x ${r% *} -y ${r#* } --down --up --delay 0.9 --udid $REF >/dev/null 2>&1 & local a=$!
  [ -n "$o" ] && $A touch -x ${o% *} -y ${o#* } --down --up --delay 0.9 --udid $OURS >/dev/null 2>&1 & local b=$!
  wait $a $b; }

# Swipe right on the bubble whose text contains TEXT, on both sides at once,
# each from its own position: swipe_text TEXT DX [HOLD]. Starts 40 pt in from the
# bubble's leading edge (incoming) or its center (mine).
swipe_text() { local t=$1 dx=$2 hold=${3:-0} r o
  r=$(center_of $REF "$t"); o=$(center_of $OURS "$t")
  [ -z "$r" ] || [ -z "$o" ] && { echo "swipe_text: '$t' not found (ref='$r' ours='$o')" >&2; return 1; }
  local rx=${r% *} ry=${r#* } ox=${o% *} oy=${o#* }
  [ $rx -lt 220 ] && rx=80; [ $ox -lt 220 ] && ox=80
  gb drag $rx $ry $((rx + dx)) $ry 0.02 ${SWIPE_V:-500} $hold -- $ox $oy $((ox + dx)) $oy 0.02 ${SWIPE_V:-500} $hold; }
