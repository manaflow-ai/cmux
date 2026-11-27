import json,sys
def summ(path):
    r=json.load(open(path))
    f0=r[0]['full']
    # handoff: first frame where google departs from its pre-handoff plateau, after the launch screen settled
    # find launch plateau: longest run of identical center values
    best=(0,0,0);i=0
    while i<len(r):
        j=i
        while j+1<len(r) and abs(r[j+1]['center']-r[i]['center'])<0.3 and abs(r[j+1]['google']-r[i]['google'])<0.3: j+=1
        if r[j]['t']-r[i]['t']>best[2]-best[1] and abs(r[i]['center']-r[i]['google'])>15 and (r[i]['google']<3 or r[i]['google']>248): best=(i,r[i]['t'],r[j]['t'],j)
        i=j+1
    pi,ps,pe,pj=best
    plate=r[pi]
    h=pj+1
    gb=plate['google']; gf=r[-1]['google']; cb=plate['centerLow']; bgc=gb  # background ~ google area pre-handoff
    zoom=next(x['t'] for x in r if abs(x['full']-f0)>1)
    settled=next(x['t'] for x in r[:h] if abs(x['center']-plate['center'])<2)
    frac=lambda x:(x['google']-gb)/(gf-gb)
    g35=next(x['t'] for x in r[h:] if frac(x)>=0.34)
    g95=next(x['t'] for x in r[h:] if frac(x)>=0.95)
    lowfrac=[(x['t'],(x['centerLow']-bgc)/(cb-bgc)) for x in r[h:h+40]]
    ghost=[ (round(t-r[h]['t'],3),round(v,2)) for t,v in lowfrac if 0.08<v<0.92]
    # stalls: gaps between distinct frames during first 0.5 s after handoff
    th=r[h]['t']; gaps=[]
    prev=r[h]
    for x in r[h+1:]:
        if x['t']-th>0.6: break
        if abs(x['google']-prev['google'])>0.05 or abs(x['lockup']-prev['lockup'])>0.05 or abs(x['full']-prev['full'])>0.05:
            gaps.append(round(x['t']-prev['t'],3)); prev=x
    return dict(zoom_start=round(zoom,3),launch_settled=round(settled,3),handoff=round(th,3),
        static_mark=round(th-settled,3), zoom_to_handoff=round(th-zoom,3),
        google_first_frac=round(frac(r[h]),2), g35=round(g35-th,3), g95=round(g95-th,3),
        zoom_to_g95=round(g95-zoom,3), ghost_frames=ghost, max_gap_first_0_6s=max(gaps) if gaps else None)
if __name__=="__main__":
  for p in sys.argv[1:]:
      print(p.split('/')[-2], json.dumps(summ(p)))
