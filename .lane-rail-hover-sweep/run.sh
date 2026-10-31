#!/bin/bash
# Scratch for lane rail-hover-sweep (not committed). Usage: run.sh LABEL [revert.patch] ...
set -uo pipefail
cd "$(dirname "$0")/../webviews"
bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null
bunx playwright install chromium >/dev/null 2>&1 || true
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/manaflow-ai/cmux.git
echo "== format diff"; if [ -n "${FMT_FILES:-}" ]; then bunx vp fmt $FMT_FILES >/tmp/fmt.log 2>&1 || tail -5 /tmp/fmt.log; git diff -- . ; git stash -q 2>/dev/null; git stash drop -q 2>/dev/null; fi
summ() {
python3 - "$1" "$2" <<'PY'
import json,sys,statistics as st
d=json.load(open(sys.argv[1]));label=sys.argv[2]
def pct(v,p):
  v=sorted(v);
  if not v: return None
  k=(len(v)-1)*p;f=int(k);c=min(f+1,len(v)-1);return round(v[f]+(v[c]-v[f])*(k-f),2)
for r in d["results"]:
  obs=[o for run in r.get("adapterRuns") or [] for o in run["observations"] if o["status"]=="painted"]
  gaps=[g for run in r.get("adapterRuns") or [] for g in (run["frameGaps"] or [])]
  sw=[o["raw"]["sweep"] for run in r.get("adapterRuns") or [] for o in run["observations"][:1]]
  lt=r.get("longTasks")
  f=lambda k:[o["raw"][k] for o in obs if o["raw"].get(k) is not None]
  avg=lambda k:round(st.mean([s[k] for s in sw if s.get(k) is not None]),3) if sw else None
  print(json.dumps({"label":label,"id":r["id"],"moves":len(obs),"errors":r["errors"][:3],
   "move_to_card_p50":pct([o["latencyMs"] for o in obs],.5),"p95":pct([o["latencyMs"] for o in obs],.95),"max":pct([o["latencyMs"] for o in obs],1),
   "move_to_tick_p50":pct(f("tickLatencyMs"),.5),"tick_p95":pct(f("tickLatencyMs"),.95),
   "frame_gap_p50":pct(gaps,.5),"frame_gap_p95":pct(gaps,.95),"frame_gap_max":pct(gaps,1),
   "commits_per_move_p50":pct(f("commits"),.5),"commits_per_move_max":pct(f("commits"),1),
   "react_ms_per_move_p50":pct(f("reactMs"),.5),"react_ms_p95":pct(f("reactMs"),.95),
   "style_recalcs_per_move":avg("recalcStylePerMove"),"style_ms_per_move":avg("recalcStyleMsPerMove"),
   "layouts_per_move":avg("layoutPerMove"),"layout_ms_per_move":avg("layoutMsPerMove"),"script_ms_per_move":avg("scriptMsPerMove"),
   "long_tasks":lt}))
PY
}
label=$1; shift
for patch in "" "$@"; do
  [ -n "${TRACE_ONLY:-}" ] && break
  if [ -n "$patch" ]; then (cd .. && git apply ${PATCH_FLAGS:-} ".lane-rail-hover-sweep/$patch") && label="$patch"; fi
  bun scripts/latency/run.ts --no-fail --engine chromium --page "chat rail sweep" --runs ${RUNS:-5} --base HEAD --json /tmp/sweep.json > /tmp/sweep.log 2>&1; echo "exit $?"; tail -15 /tmp/sweep.log
  summ /tmp/sweep.json "$label"
done
if [ -n "${TRACE:-}" ]; then for n in ${TRACE_TURNS:-100}; do for m in ${MODES:-""}; do echo "== trace $n $m"; MODE=$m TURNS=$n timeout 900 bun ../.lane-rail-hover-sweep/trace.ts 2>&1 | tail -${TRACE_LINES:-150}; done; done; fi
if [ -n "${CULPRIT:-}" ]; then [ -n "${CULPRIT_PATCH:-}" ] && git apply "../.lane-rail-hover-sweep/$CULPRIT_PATCH"; timeout 1500 bun ../.lane-rail-hover-sweep/culprit.ts 2>&1 | tail -30; fi
