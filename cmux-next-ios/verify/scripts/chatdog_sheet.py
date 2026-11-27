import sys,os
from PIL import Image, ImageDraw
d,out,step,cols=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
fs=sorted(os.listdir(d))[::step]
ims=[Image.open(os.path.join(d,f)) for f in fs]
w,h=ims[0].size; rows=(len(ims)+cols-1)//cols
S=Image.new('RGB',(cols*(w+4),rows*(h+4)),'gray')
for i,im in enumerate(ims):
    x,y=(i%cols)*(w+4),(i//cols)*(h+4); S.paste(im,(x,y)); ImageDraw.Draw(S).text((x+4,y+4),fs[i],fill='red')
S.save(out); print(out, len(ims))
