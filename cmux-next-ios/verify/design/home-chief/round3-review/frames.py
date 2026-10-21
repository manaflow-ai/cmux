import json,sys
def walk(n,out):
    f=n.get("frame") or {}
    u=n.get("AXUniqueId") or ""; l=(n.get("AXLabel") or "")[:60]
    if u or l: out.append((round(f.get("y",0)),round(f.get("y",0)+f.get("height",0)),round(f.get("x",0)),round(f.get("width",0)),n.get("type"),u,l))
    for c in n.get("children") or []: walk(c,out)
out=[]
for n in json.load(open(sys.argv[1])): walk(n,out)
for r in out:
    if r[0]<int(sys.argv[2]) if len(sys.argv)>2 else True: print(r)
