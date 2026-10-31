# tile.py <framesdir> <out.png> <title> : 16 frames from 2 before handoff, labeled with seconds since handoff
import json,sys,numpy as np
from PIL import Image,ImageDraw,ImageFont
d,out,title=sys.argv[1],sys.argv[2],sys.argv[3]
r=json.load(open(d+'/metrics.json'))
sys.path.insert(0,'/tmp/cmux-mobile-ob-review2/scripts')
import summary
s=summary.summ(d+'/metrics.json')
h=next(i for i,x in enumerate(r) if abs(x['t']-s['handoff'])<0.0021)
# pick distinct-time frames
idx=[];last=None
for i in range(h-2,len(r)):
    if last is None or r[i]['t']-last>0.012: idx.append(i); last=r[i]['t']
    if len(idx)==16: break
W=201;H=437
font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',14)
canvas=Image.new('RGB',(W*8,(H+22)*2+30),(40,40,40))
dr=ImageDraw.Draw(canvas); dr.text((6,6),title,fill=(255,255,255),font=font)
for k,i in enumerate(idx):
    im=Image.open('%s/f_%05d.png'%(d,i+1)).convert('RGB').resize((W,H),Image.LANCZOS)
    x=(k%8)*W; y=30+(k//8)*(H+22)
    canvas.paste(im,(x,y+22)); dr.text((x+4,y+3),'#%d %+.3fs'%(k,r[i]['t']-s['handoff']),fill=(255,255,0),font=font)
canvas.save(out)
