# analyze.py <video.mp4> <outdir>  — per-frame metrics using true pts (VFR passthrough)
import sys, subprocess, os, glob, json
import numpy as np
from PIL import Image
vid, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for f in glob.glob(out+'/f_*.png'): os.remove(f)
# frames with real timestamps
r = subprocess.run(['ffmpeg','-v','info','-i',vid,'-fps_mode','passthrough','-vf','showinfo',out+'/f_%05d.png'],capture_output=True,text=True)
pr=subprocess.run(['ffprobe','-v','error','-select_streams','v','-show_entries','frame=pts_time','-of','csv=p=0',vid],capture_output=True,text=True)
pts=[float(x.strip(',')) for x in pr.stdout.split()]
files=sorted(glob.glob(out+'/f_*.png'))
S=3
def box(a,x0,y0,x1,y1): return a[int(y0*S):int(y1*S), int(x0*S):int(x1*S)]
rows=[]
first=np.asarray(Image.open(files[0]).convert('L'),dtype=np.float32)
H,W=first.shape
cx,cy=W/S/2,H/S/2
for i,(f,t) in enumerate(zip(files,pts)):
    a=np.asarray(Image.open(f).convert('L'),dtype=np.float32)
    rows.append(dict(i=i,t=t,
      center=float(box(a,cx-36,cy-36,cx+36,cy+36).mean()),
      centerLow=float(box(a,cx-36,cy+8,cx+36,cy+36).mean()),   # below headline band
      google=float(box(a,40,628,362,654).mean()),
      headline=float(box(a,40,404,362,444).mean()),
      lockup=float(box(a,150,66,260,98).mean()),
      full=float(a.mean())))
json.dump(rows,open(out+'/metrics.json','w'))
print(len(rows),'frames', W,'x',H)
