#!/usr/bin/env python3
"""Per-turn Chief numbers from optchat traces: ttft, turn time, cache hit, cold turns, cost.
usage: chief_trace_stats.py TRACE.jsonl [...]  (read-only)"""
import json,sys,statistics as st
def pct(a,p):
  a=sorted(x for x in a if x is not None); return a[min(len(a)-1,int(p*len(a)))] if a else None
turns=[];reqs=[];nodes=[];subs=[]
for f in sys.argv[1:]:
  for l in open(f):
    try:d=json.loads(l)
    except:continue
    e=d.get('ev')
    if e=='turn.end' and d.get('status')=='ok':turns.append(d)
    elif e=='request':reqs.append(d)
    elif e=='node' and d.get('ok'):nodes.append(d)
    elif e=='subagent.answer':subs.append(d)
def hit(u):
  t=u.get('cache_read',0)+u.get('cache_write',0)+u.get('input',0); return u.get('cache_read',0)/t if t else 0
def agg(us):
  r=sum(u.get('cache_read',0) for u in us); w=sum(u.get('cache_write',0) for u in us); i=sum(u.get('input',0) for u in us)
  return r,w,i,(r/(r+w+i) if r+w+i else 0)
print('Chief turns',len(turns))
for k in ['ttft_ms','ms','start_ms','requests','tools']:
  a=[t[k] for t in turns if isinstance(t.get(k),(int,float))]
  print(f'  {k}: p50 {pct(a,.5)} p90 {pct(a,.9)}')
c=[t['cost_usd'] for t in turns if t.get('cost_usd') is not None]
print(f'  cost/turn p50 {pct(c,.5):.4f} mean {st.mean(c):.4f} total {sum(c):.2f}')
fu=[t['first_usage'] for t in turns if t.get('first_usage')]
r,w,i,h=agg(fu); print(f'  first request: read {r//len(fu)} write {w//len(fu)} input {i//len(fu)} avg, hit {h:.3f}')
tot=[sum(t['first_usage'].values()) - t['first_usage'].get('output',0) for t in turns if t.get('first_usage')]
print(f'  first-request prompt tokens p50 {pct(tot,.5)} p90 {pct(tot,.9)}')
r,w,i,h=agg([q['usage'] for q in reqs if q.get('usage')]); print(f'  all requests ({len(reqs)}): read {r} write {w} input {i} hit {h:.3f}')
hm=[q['headers_ms'] for q in reqs if q.get('headers_ms')]; print(f'  request headers_ms p50 {pct(hm,.5)} p90 {pct(hm,.9)}')
print('Compactor nodes',len(nodes))
r,w,i,h=agg([n['usage'] for n in nodes]); print(f'  hit {h:.3f}; ms p50 {pct([n["ms"] for n in nodes],.5)}; ttft p50 {pct([n["timing"]["ttft_ms"][0] for n in nodes if n.get("timing",{}).get("ttft_ms")],.5)}; session_start p50 {pct([n["timing"].get("session_start_ms") for n in nodes if n.get("timing",{}).get("session_start_ms") is not None],.5)}; cost total {sum(n.get("cost_usd") or 0 for n in nodes):.2f}')
print('Subagent answers',len(subs))
r,w,i,h=agg([s['usage'] for s in subs if s.get('usage')]); print(f'  read {r} write {w} input {i} hit {h:.3f} cost {sum(s.get("cost_usd") or 0 for s in subs):.2f}')
z=[s for s in subs if s.get('usage') and s['usage'].get('cache_read',0)==0 and s['usage'].get('input',0)>100000]
print(f'  zero-cache-read answers with >100k input: {len(z)}, cost {sum(s.get("cost_usd") or 0 for s in z):.2f}')
