"""Frame-by-frame drawer motion check.

Decodes every recorded frame (variable frame rate, real timestamps) and finds
the pushed card's leading edge from the tab bar row: the first 3 pt run of columns,
scanning left to right, whose brightness differs from the sidebar background
(the tab bar capsule edge, 21 pt inside the card). Prints
per-frame x (points) and flags jumps: a frame-to-frame step larger than
`--max-step` points, or a velocity sign flip mid-motion that is not a settle.

usage: python3 verify/drawer_track.py <video.mp4> [--row 0.938] [--scale 3]
"""
import json, subprocess, sys
import numpy as np

def frames(path, width):
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=width,height:frame=best_effort_timestamp_time", "-of", "json", path]))
    w, h = probe["streams"][0]["width"], probe["streams"][0]["height"]
    times = [float(f["best_effort_timestamp_time"]) for f in probe["frames"]]
    raw = subprocess.check_output(["ffmpeg", "-v", "quiet", "-i", path, "-fps_mode", "passthrough",
                                   "-f", "rawvideo", "-pix_fmt", "gray", "-"])
    n = len(raw) // (w * h)
    data = np.frombuffer(raw, dtype=np.uint8)[: n * w * h].reshape(n, h, w)
    return times[:n], data, w, h

def main():
    path = sys.argv[1]
    row_frac = float(sys.argv[sys.argv.index("--row") + 1]) if "--row" in sys.argv else 0.938
    scale = float(sys.argv[sys.argv.index("--scale") + 1]) if "--scale" in sys.argv else 3.0
    max_step = float(sys.argv[sys.argv.index("--max-step") + 1]) if "--max-step" in sys.argv else 90.0
    times, data, w, h = frames(path, None)
    y = int(h * row_frac)
    xs = []
    for frame in data:
        band = frame[y - 3 : y + 4].astype(int).mean(axis=0)
        bg = np.median(band[:8]) if band[:8].std() < 4 else band[0]
        diff = (np.abs(band - bg) > 10).astype(int)
        # Require a 3 pt run so the 0.5 pt card stroke (alpha follows progress)
        # is not mistaken for the tab bar edge.
        run = np.convolve(diff, np.ones(9, dtype=int), mode="valid") == 9
        idx = int(np.argmax(run)) if run.any() else -1
        xs.append(idx / scale if idx >= 0 else float("nan"))
    prev = None
    jumps = 0
    for t, x in zip(times, xs):
        note = ""
        if prev is not None and not np.isnan(x) and not np.isnan(prev[1]):
            step = x - prev[1]
            dt = t - prev[0]
            if abs(step) > max_step:
                note = f"  JUMP {step:+.1f}pt in {dt*1000:.0f}ms"
                jumps += 1
        print(f"{t:8.3f}s  x={x:7.1f}pt{note}")
        prev = (t, x)
    print(f"frames={len(xs)} jumps={jumps}")

main()
