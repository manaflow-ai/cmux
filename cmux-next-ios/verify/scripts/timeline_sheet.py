"""timeline_sheet.py <label-path-without-ext> <out.png> [offset-s] [width]
One frame per demo timeline mark (mark time + offset, default 0.9 s), side by
side, labeled with the mark. Uses <label>.mp4, .timeline.txt, .recstart.txt
(video t=0 = recstart + 2 s, see record_flow.sh)."""
import subprocess, sys, tempfile, os
from PIL import Image, ImageDraw
base, out = sys.argv[1], sys.argv[2]
off = float(sys.argv[3]) if len(sys.argv) > 3 else 0.9
W = int(sys.argv[4]) if len(sys.argv) > 4 else 260
r = float(open(base + ".recstart.txt").read()) + 2
marks = [l.split(" ", 1) for l in open(base + ".timeline.txt").read().splitlines() if l.strip()]
ims = []
with tempfile.TemporaryDirectory() as tmp:
    for i, (t, label) in enumerate(marks):
        f = os.path.join(tmp, f"{i}.png")
        ts = max(0, float(t) - r + off)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{ts:.2f}", "-i", base + ".mp4", "-frames:v", "1",
                        "-vf", f"scale={W}:-1", f], check=True)
        if os.path.exists(f):  # marks after the recording ended have no frame
            ims.append((Image.open(f).convert("RGB"), f"{ts:.1f}s {label}"[:40]))
w, h = ims[0][0].size
cols = min(10, len(ims)); rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (w + 4), rows * (h + 18)), (255, 0, 255))
d = ImageDraw.Draw(sheet)
for i, (im, label) in enumerate(ims):
    x, y = (i % cols) * (w + 4), (i // cols) * (h + 18)
    sheet.paste(im, (x, y + 18)); d.text((x + 3, y + 3), label, fill=(255, 255, 255))
sheet.save(out)
