import sys
from PIL import Image
out=sys.argv[1]; ims=[Image.open(p) for p in sys.argv[2:]]
w=sum(i.width for i in ims)+10*(len(ims)-1); h=max(i.height for i in ims)
S=Image.new('RGB',(w,h),'gray'); x=0
for i in ims: S.paste(i,(x,0)); x+=i.width+10
S.save(out)
