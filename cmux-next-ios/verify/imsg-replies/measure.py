import sys
W,H=1320,2868
d=open(sys.argv[1] if len(sys.argv)>1 else 'device.rgb','rb').read()
def px(x,y): i=(y*W+x)*3; return d[i],d[i+1],d[i+2]
def isline(c): r,g,b=c; return r==g==b and 38<=r<=44
def isblue(c): r,g,b=c; return b>220 and 55<=r<=80 and 130<=g<=160
def isinc(c): r,g,b=c; return (r,g,b)==(38,38,41)
def bbox(x0,x1,y0,y1,f):
    xs=[];ys=[]
    for y in range(y0,y1):
        for x in range(x0,x1):
            if f(px(x,y)): xs.append(x); ys.append(y)
    if not xs: return None
    return (min(xs)/3,min(ys)/3,max(xs)/3,max(ys)/3)
def show(n,b): print(f"{n:28s}", None if b is None else "x %.1f-%.1f  y %.1f-%.1f  (w %.1f h %.1f)"%(b[0],b[2],b[1],b[3],b[2]-b[0],b[3]-b[1]))
def outline(x0,x1,y0,y1,lo,hi,blue=False):
    def f(c):
        r,g,b=c
        if blue: return 5<=r<=20 and 25<=g<=45 and 50<=b<=75
        return r==g==b and lo<=r<=hi
    return bbox(x0,x1,y0,y1,f)
