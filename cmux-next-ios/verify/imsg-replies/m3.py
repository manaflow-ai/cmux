W,H=1320,2868
def load(p): return open(p,'rb').read()
def px(d,x,y): i=(y*W+x)*3; return d[i],d[i+1],d[i+2]
def vr(d,x,pred,y0,y1):
    out=[];cur=None
    for y in range(max(0,y0),min(H,y1)):
        if pred(px(d,x,y)):
            if cur and y-cur[1]<=1: cur[1]=y
            else:
                if cur: out.append(cur)
                cur=[y,y]
    if cur: out.append(cur)
    return [(a/3,(b+1)/3) for a,b in out]
blueol=lambda c: c[2]>40 and c[2]>c[0]+25 and c[2]<200 and c[1]<110
grayol=lambda c: c[0]==c[1]==c[2] and 47<=c[0]<=62
line=lambda c: c==(41,41,41)
inc=lambda c: c==(38,38,41)
outb=lambda c: c[2]>235 and c[0]<90 and c[1]<160
label=lambda c: c[2]>200 and c[0]<80 and 110<c[1]<170
def bandsx(d,x0,x1,pred,y0,y1):
    out=[];cur=None
    for y in range(int(y0*3),int(y1*3)):
        if any(pred(px(d,x,y)) for x in range(int(x0*3),int(x1*3),2)):
            if cur and y-cur[1]<=2: cur[1]=y
            else:
                if cur: out.append(cur)
                cur=[y,y]
    if cur: out.append(cur)
    return [(round(a/3,1),round((b+1)/3,1)) for a,b in out]
def measure(d, qx, qguess, labx, rx, rpred, qpred):
    q=vr(d,int(qx*3),qpred,int((qguess-25)*3),int((qguess+45)*3))
    qt=q[0][0]; qb=max(r[1] for r in q if r[0]<qt+33)
    lab=[b for b in bandsx(d,labx[0],labx[1],label,qb,qb+22) if b[1]-b[0]>6]
    start=lab[0][1] if lab else qb
    rep=vr(d,int(rx*3),rpred,int((start+0.5)*3),int((start+60)*3))
    ln=bandsx(d,30,72,line,qt-5,qt+130)
    f=lambda v: round(v-qt,1)
    return dict(quote_h=round(qb-qt,1), label=[(f(a),f(b)) for a,b in lab[:1]], reply_top=f(rep[0][0]) if rep else None, line=(f(ln[0][0]),f(ln[-1][1])) if ln else None)
import sys
d=load(sys.argv[1])
for name,args in [("P1 their->mine", (376,float(sys.argv[2]),(345,415),150,inc,blueol)),
                  ("P2 mine->mine", (376,float(sys.argv[3]),(345,415),400,outb,blueol)),
                  ("P3 mine->theirs",(130,float(sys.argv[4]),(30,95),400,outb,grayol))]:
    print("  ",name, measure(d,*args))
