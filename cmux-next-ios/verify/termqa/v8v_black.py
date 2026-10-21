"""Round-8 verifier: black terminal band per SOURCE frame of a simulator recording
(no resampling), with each black frame's on-screen duration (next frame pts - pts).

    python3 v8v_black.py VIDEO [--top 70] [--bottom 699] [--json OUT]

Band in points (402 x 874 screen). Black: lit (luma > 60) < 0.4 % while the run's
median lit >= 1.6 % (ACCEPTANCE section 0). Runs merge consecutive black frames.
"""
import argparse
import json
import subprocess

import numpy as np

W, H = 201, 437  # 0.5 px per pt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--top", type=float, default=70)
    ap.add_argument("--bottom", type=float, default=699)
    ap.add_argument("--json")
    a = ap.parse_args()
    pts = [float(x.strip(",")) for x in subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                                             "-of", "csv=p=0", a.video], capture_output=True, text=True).stdout.split() if x.strip(", ")]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", a.video, "-fps_mode", "passthrough", "-vf", f"scale={W}:{H},format=gray",
                          "-f", "rawvideo", "-"], capture_output=True).stdout
    n = len(raw) // (W * H)
    fr = np.frombuffer(raw[: n * W * H], dtype=np.uint8).reshape(n, H, W)
    y0, y1 = int(a.top / 2), int(a.bottom / 2)
    lit = (fr[:, y0:y1, :] > 60).mean(axis=(1, 2))
    pts = pts[:n]
    med = float(np.median(lit))
    black = (lit < 0.004) & (med >= 0.016)
    runs, i = [], 0
    while i < n:
        if black[i]:
            j = i
            while j + 1 < n and black[j + 1]:
                j += 1
            end = pts[j + 1] if j + 1 < n else pts[j]
            runs.append({"start": round(pts[i], 3), "end": round(end, 3), "dur_ms": round((end - pts[i]) * 1000, 1), "source_frames": j - i + 1})
            i = j + 1
        else:
            i += 1
    gaps = np.diff(pts) if n > 1 else np.array([0])
    out = {"video": a.video, "source_frames": n, "duration": round(pts[-1] - pts[0], 2) if n else 0, "lit_median": round(med, 4),
           "black_runs": runs, "black_runs_over_17ms": [r for r in runs if r["dur_ms"] > 17.5],
           "frac_gaps_over_34ms": round(float((gaps > 0.034).mean()), 4), "max_gap_ms": round(float(gaps.max()) * 1000, 1)}
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "black_runs"}, indent=1))
    print("runs:", [(r["start"], r["dur_ms"]) for r in runs])


if __name__ == "__main__":
    main()
