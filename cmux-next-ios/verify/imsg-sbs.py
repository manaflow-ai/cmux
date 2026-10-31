"""Side-by-side sheets for verify/imsg-parity.sh: ref | ours | pixel diff
(pixels differing by more than 24 of 255), scaled to points, and the diff's
bounding box and changed share. usage: imsg-sbs.py <out-dir> <state>..."""
import sys
from PIL import Image, ImageChops
d=sys.argv[1]
for n in sys.argv[2:]:
    a=Image.open(f'{d}/{n}-ref.png').convert('RGB');b=Image.open(f'{d}/{n}-ours.png').convert('RGB')
    w,h=a.size
    diff=ImageChops.difference(a,b).convert('L').point(lambda v:255 if v>24 else 0)
    s=Image.new('RGB',(w*3+40,h),'red');s.paste(a,(0,0));s.paste(b,(w+20,0));s.paste(diff.convert('RGB'),(2*w+40,0))
    s.resize((s.width//3,s.height//3)).save(f'{d}/{n}-sbs.png')
    bb=diff.getbbox(); frac=sum(1 for v in diff.getdata() if v)/ (w*h)
    print(n, 'diff bbox(pt)=', tuple(round(x/3) for x in bb) if bb else None, f'changed={frac*100:.2f}%')
