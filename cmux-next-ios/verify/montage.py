"""Side-by-side comparison strip: every panel scaled to 900 px tall and labeled.

usage: python3 verify/montage.py <out.png> <source>...
A source is an image path or <video.mp4>@<seconds> (the frame at that time).
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

out, sources = sys.argv[1], sys.argv[2:]
panels = []
with tempfile.TemporaryDirectory() as tmp:
    for i, src in enumerate(sources):
        if ".mp4@" in src:
            path, t = src.rsplit("@", 1)
            frame = os.path.join(tmp, f"{i}.png")
            # The recorder writes frames only on change (variable frame rate), so
            # take the last frame at or before t, not the next one after it.
            subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-i", path, "-vf", f"select='lte(t,{t})'",
                            "-fps_mode", "passthrough", "-update", "1", frame], check=True)
            label = f"{os.path.splitext(os.path.basename(path))[0]} @{t}s"
        else:
            frame, label = src, os.path.splitext(os.path.basename(src))[0]
        img = Image.open(frame).convert("RGB")
        img = img.resize((round(img.width * 900 / img.height), 900))
        panel = Image.new("RGB", (img.width, 940), (90, 90, 90))
        panel.paste(img, (0, 40))
        ImageDraw.Draw(panel).text((8, 8), label, fill="white", font=ImageFont.load_default(size=20))
        panels.append(panel)
strip = Image.new("RGB", (sum(p.width for p in panels) + 8 * (len(panels) - 1), 940), (40, 40, 40))
x = 0
for p in panels:
    strip.paste(p, (x, 0))
    x += p.width + 8
strip.save(out)
print(out)
