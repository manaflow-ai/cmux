"""Pick the frame of a recording that differs most from its first frame (the
deepest point of a gesture: the send-time drawer held open, an edge swipe at
its widest) and save it full size as <out>/<name>-<side>.png for imsg-sbs.py.
usage: imsg-peak.py <out-dir> <recording> <name>"""
import subprocess, sys, tempfile, glob, os
from PIL import Image, ImageChops
out, rec, name = sys.argv[1:4]
for side in ("ref", "ours"):
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-i", f"{out}/{rec}-{side}.mp4", "-vf", "fps=15", f"{d}/f%04d.png"], check=True)
        frames = sorted(glob.glob(f"{d}/*.png"))
        first = Image.open(frames[0]).convert("L").resize((220, 478))
        def score(f):
            return sum(ImageChops.difference(first, Image.open(f).convert("L").resize((220, 478))).getdata())
        best = max(frames, key=score)
        Image.open(best).save(f"{out}/{name}-{side}.png")
        print(name, side, os.path.basename(best), "of", len(frames))
