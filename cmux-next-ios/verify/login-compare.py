import sys, subprocess, os
# Side-by-side timeline: reference video frames (at t0 + t) above rows of
# frozen-intro screenshots from verify/login-timeline.sh, at matching t.
# usage: python3 verify/login-compare.py <ref.mp4> <ref t0> <dir> <label> [<dir> <label>...] <out.png>
from PIL import Image, ImageDraw, ImageFont
vid, t0 = sys.argv[1], float(sys.argv[2]); out = sys.argv[-1]
pairs = list(zip(sys.argv[3:-1:2], sys.argv[4:-1:2]))
times = [0, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6.5]
W = 200
tmp = '/tmp/cmux-mobile-login-compare-ref'; os.makedirs(tmp, exist_ok=True)
def fit(im):
    im = im.convert('RGB'); return im.resize((W, int(im.height * W / im.width)))
rows = []
cl = []
for t in times:
    p = f'{tmp}/{t}.png'
    subprocess.run(['ffmpeg','-v','error','-y','-ss',str(t0+t),'-i',vid,'-frames:v','1',p], check=True)
    cl.append(fit(Image.open(p)))
rows.append(('Claude (ref)', cl))
for d, label in pairs:
    rows.append((label, [fit(Image.open(f'{d}/t{t}.png' if os.path.exists(f'{d}/t{t}.png') else f'{d}/t{int(t)}.png')) for t in times]))
H = max(r[1][0].height for r in rows)
lab = 26; side = 110
sheet = Image.new('RGB', (side + W * len(times), lab + H * len(rows)), (40, 40, 40))
d = ImageDraw.Draw(sheet)
try: font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 16)
except Exception: font = None
for i, t in enumerate(times):
    d.text((side + i * W + 8, 4), f't = {t:.2f} s', fill='yellow', font=font)
for r, (label, ims) in enumerate(rows):
    d.text((6, lab + r * H + H // 2), label, fill='white', font=font)
    for i, im in enumerate(ims):
        sheet.paste(im, (side + i * W, lab + r * H))
sheet.save(out); print(out, sheet.size)
