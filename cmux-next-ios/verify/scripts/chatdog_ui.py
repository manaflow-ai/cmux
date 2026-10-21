import json,sys
d=json.load(sys.stdin)
def w(n,dep=0):
    l=n.get("AXLabel") or ""; t=n.get("type") or n.get("role"); f=n.get("frame") or {}; v=n.get("AXValue")
    if l or v:
        print("  "*dep+"%s [%s] v=%s @(%.0f,%.0f,%.0fx%.0f)"%(t,l,v,f.get("x",0),f.get("y",0),f.get("width",0),f.get("height",0)))
    for c in n.get("children",[]) or []: w(c,dep+1)
for n in (d if isinstance(d,list) else [d]): w(n)
