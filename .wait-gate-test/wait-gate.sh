# wait-gate.sh: sourced. gw OK_CODES -- glaeda-gh wait ...: run the wait, print its last 2 lines, and
# exit the calling script with 9 unless the wait's own exit code is one of OK_CODES (comma list).
# glaeda-gh wait codes: 0 ok, 1 finished red, 2 timed out, 3 daemon down, 4 conflict, 6 nothing reported.
# A timed-out or failed wait never falls through to a retarget or merge (dep-fleet-6, 2026-11-11, #41295).
gw() {
  local ok=$1; shift; [ "$1" = -- ] && shift
  local out rc; out=$("$@" 2>&1); rc=$?
  printf '%s\n' "$out" | tail -2
  case ",$ok," in *",$rc,"*) return 0 ;; esac
  echo "HOLD: wait exited $rc (not in {$ok}): $*; stopping before any retarget or merge"
  exit 9
}
