cd webviews
for s in 1150 1153 1154 1156 1166 1172 1177 1200 1203; do
  echo "=== STEP $s"
  CHAT_SIM_DUMP="file:test/fixtures/chat-sim/leo-0522-midturn-inbox.ndjson:$s" bun test test/chat-sim-browser.test.ts 2>&1 | python3 -c '
import sys,json,re
t=sys.stdin.read()
m=re.search(r"^\[\s*\{.*?^\]", t, re.S|re.M)
if not m: print(t[-800:]); sys.exit()
rows=json.loads(m.group(0))
i=max([k for k,r in enumerate(rows) if str(r.get("id","")).startswith("summary")] or [0])
for r in rows[max(0,i-2):]: print("  ", {k:v for k,v in r.items() if k in ("id","kind","top","bottom","height","gap","marginTop")})
'
done
