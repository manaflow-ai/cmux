"""Self-test for rows.py: render a synthetic 1206x2622 terminal recording of numbered rows
(PIL + ffmpeg), with known defects, and check the tracker finds exactly them.

    python3 rows_selftest.py [--keep DIR]

Script (10 fps, 6 s): frames 0-19 follow (one new row per frame), 20-39 read (window fixed;
frame 25 is a foreign frame from far away in history; from frame 30 the rows sit 3 pt =
9 px lower: one drift step), 40-59 follow again, except frame 45 shows the window 3 rows
behind where it should be, 2 behind frame 44 (a backstep).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
W, H, K = 1206, 2622, 3          # px, px per pt
PITCH = 16 * K                   # row pitch px
TOP, ROWS = 70 * K, 42           # first row y, visible rows (70..742 pt)


def render(path, first, dy_px=0):
    im = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(im)
    font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 13 * K)
    for r in range(ROWS):
        n = first + r
        d.text((6 * K, TOP + r * PITCH + dy_px), "#%07d 1792017856%03d tango lima echo %d" % (n, n % 1000, n), fill=230, font=font)
    d.rectangle((0, 790 * K, W, 830 * K), fill=40)          # a composer-like bar below the band
    im.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep")
    a = ap.parse_args()
    d = a.keep or tempfile.mkdtemp(prefix="tqrows-selftest-")
    os.makedirs(d, exist_ok=True)
    script = []
    for i in range(60):
        if i < 20:
            first = 100 + i
        elif i < 40:
            first = 120
        else:
            first = 120 + (i - 39)
        dy = 9 if 30 <= i < 40 else 0
        if i == 25:
            first, dy = 5000, 0
        if i == 45:
            first -= 3
        script.append((first, dy))
        render(os.path.join(d, "s%03d.png" % i), first, dy)
    video = os.path.join(d, "synthetic.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", "10", "-i", os.path.join(d, "s%03d.png"),
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", video], check=True)
    out = os.path.join(d, "rows.json")
    subprocess.run([sys.executable, os.path.join(HERE, "rows.py"), video, "--fps", "10", "--json", out, "--quiet"],
                   check=True)
    s = json.load(open(out))["summary"]
    fails = []
    foreign = [f["t"] for f in s["foreign_frames"]]
    if foreign != [2.5]:
        fails.append(f"foreign frames {foreign}, want [2.5]")
    back = [(b["t"], b["rows"]) for b in s["backsteps"]]
    if back != [(4.5, 2)]:
        fails.append(f"backsteps {back}, want [(4.5, 2)] (2 rows behind frame 44)")
    drift = [(x["t"], x["dy_px"]) for x in s["drift_frames"]]
    if len(drift) != 1 or drift[0][0] != 3.0 or abs(drift[0][1] - 9) > 2:
        fails.append(f"drift frames {drift}, want one at 3.0 s of ~9 px")
    if s["frames_with_ids"] != 60 or s["id_min"] != 100 or s["id_max"] != 5000 + ROWS - 1:
        fails.append(f"frames_with_ids {s['frames_with_ids']}, ids {s['id_min']}..{s['id_max']}")
    print(json.dumps({k: s[k] for k in ("frames_with_ids", "id_min", "id_max", "foreign_frames", "backsteps",
                                        "drift_frames", "max_read_drift_px")}, indent=1))
    if not a.keep:
        shutil.rmtree(d, ignore_errors=True)
    if fails:
        sys.exit("FAIL: " + "; ".join(fails))
    print("PASS")


if __name__ == "__main__":
    main()
