import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert("RGB"); x=int(sys.argv[2])*3
y0,y1=int(sys.argv[3])*3,int(sys.argv[4])*3
prev=None; start=y0
for y in range(y0,y1):
    p=im.getpixel((x,y)); k=tuple(v//6 for v in p)
    if prev is not None and max(abs(a-b) for a,b in zip(k,prev))>1:
        print(f"{start/3:.1f}-{y/3:.1f} rgb{im.getpixel((x,start))}"); start=y
    prev=k
print(f"{start/3:.1f}-{y1/3:.1f} rgb{im.getpixel((x,start))}")
