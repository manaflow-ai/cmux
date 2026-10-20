"""Row-identity tracker (M-ROWS, ACCEPTANCE.md gap G-03): OCR the numbered row ids
(`#%07d`, printed by fixtures/*.py) visible in each frame of a terminal recording.

    python3 rows.py VIDEO [--fps 10] [--start S] [--dur D] [--top 50] [--bottom 760]
                          [--left 0] [--width 402] [--jobs 2] [--json OUT] [--video-start EPOCH] [--quiet]

Band: points (402x874 space) from --top to --bottom, --left/--width horizontally (narrow
it to the id column to make OCR faster). Frames are cropped at full resolution and read
by ~/cmux-next-ios-e2e/bin/ocr-batch (built from e2e/ocr_batch.swift on first use).

Per frame: the ids with their y (pt), the visible window (min, max), contiguity breaks
inside the frame (ids not increasing by the row step their y distance implies), and the
y drift of ids shared with the previous frame. Across frames: foreign frames (window
disjoint from both neighbours while the neighbours overlap, or an internal break),
bounces (content moves >= half a row and straight back the next frame; a backstep when
it first moves down, i.e. back in history), and read-row drift (the median y change of
shared ids while no row scrolled in or out, |dy| < half of --row-pt; > 1 px = not zero
drift). --pattern swaps the id regex (e.g. Codex's numbered list `^(\d{1,4})\.`). With
--video-start (host epoch of video t=0) and rows that carry `<send-epoch-ms>`, the lag of
the newest row (first frame it is visible minus its send time).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OCR_SRC = os.path.join(HERE, "..", "e2e", "ocr_batch.swift")
OCR_BIN = os.path.expanduser("~/cmux-next-ios-e2e/bin/ocr-batch")
SCREEN_W = 402
# OCR confusables in the 7 id digits: Latin/Cyrillic O, I/l/|, S, B.
ID_RE = re.compile("(?:^|(?<=\\s))[#H*]\\s?([0-9OoIl|SB\u041e\u043e]{7})(?![0-9])(?:\\s*(\\d{13}))?")
FIX = str.maketrans("OoIl|SB\u041e\u043e", "001115800")


def ocr_bin():
    if not os.path.exists(OCR_BIN) or os.path.getmtime(OCR_BIN) < os.path.getmtime(OCR_SRC):
        os.makedirs(os.path.dirname(OCR_BIN), exist_ok=True)
        subprocess.run(["xcrun", "swiftc", "-O", OCR_SRC, "-o", OCR_BIN], check=True)
    return OCR_BIN


def extract(video, a, d):
    vw = int(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width",
                             "-of", "csv=p=0", video], capture_output=True, text=True, check=True).stdout.strip())
    k = vw / SCREEN_W
    crop = f"crop={int(a.width * k)}:{int((a.bottom - a.top) * k)}:{int(a.left * k)}:{int(a.top * k)}"
    cmd = ["ffmpeg", "-v", "error", "-y"] + (["-ss", str(a.start)] if a.start else []) + \
          (["-t", str(a.dur)] if a.dur else []) + ["-i", video, "-vf", f"fps={a.fps},{crop},format=gray",
                                                   os.path.join(d, "f%05d.png")]
    subprocess.run(cmd, check=True)
    return k, sorted(f for f in os.listdir(d) if f.endswith(".png"))


def ocr(paths, k, jobs, accurate=False):
    # Vision's fast level reads digit runs at full resolution reliably; the accurate level
    # garbles the last digit of `#0000112` (seen on Menlo renders), and is 4x slower.
    out = subprocess.run([ocr_bin(), "--scale", str(k), "--jobs", str(jobs)] + ([] if accurate else ["--fast"]),
                         input="\n".join(paths),
                         capture_output=True, text=True, check=True).stdout
    res, cur = {}, None
    for line in out.splitlines():
        if line.startswith("== "):
            cur = line[3:]
            res[cur] = []
        elif cur and "\t" in line:
            geo, text = line.split("\t", 1)
            x, y, w, h = (float(v) for v in geo.split())
            res[cur].append((x, y, w, h, text))
    return res


def parse(obs, top, left, id_re=None):
    """ids in one frame: {id: (y_pt, send_ms|None, x_pt)}; first occurrence by y wins. When
    OCR splits the id and its send time into two boxes, the 13-digit box on the same line
    supplies the time."""
    ids = {}
    stamps = [(y, int(t[:13])) for x, y, w, h, t in obs if re.match(r"\d{13}(?!\d)", t)]
    for x, y, w, h, text in sorted(obs, key=lambda o: o[1]):
        for m in (id_re or ID_RE).finditer(text):
            n = int(m.group(1).translate(FIX))
            if n in ids:
                continue
            ms = int(m.group(2)) if m.re.groups > 1 and m.group(2) else next((v for sy, v in stamps if abs(sy - y) < 4), None)
            ids[n] = (round(y + top, 2), ms, round(x + left, 1))
    return ids


def breaks_in(ids):
    """Adjacent ids (by y) whose id step disagrees with the y distance."""
    rows = sorted((v[0], n) for n, v in ids.items())
    steps = [(rows[i + 1][0] - rows[i][0]) for i in range(len(rows) - 1) if rows[i + 1][1] - rows[i][1] == 1]
    if not steps:
        return [] if all(rows[i + 1][1] > rows[i][1] for i in range(len(rows) - 1)) else \
            [(rows[i][1], rows[i + 1][1]) for i in range(len(rows) - 1) if rows[i + 1][1] <= rows[i][1]]
    steps.sort()
    pitch = steps[len(steps) // 2]
    out = []
    for (y0, a), (y1, b) in zip(rows, rows[1:]):
        d = b - a
        if d <= 0 or (d > 1 and abs((y1 - y0) / pitch - d) > 0.5):
            out.append((a, b))
    return out


def main():
    ap = argparse.ArgumentParser(description="OCR row-id tracker (M-ROWS)")
    ap.add_argument("video")
    ap.add_argument("--fps", type=float, default=10)
    ap.add_argument("--start", type=float)
    ap.add_argument("--dur", type=float)
    ap.add_argument("--top", type=float, default=50, help="band top, pt")
    ap.add_argument("--bottom", type=float, default=760, help="band bottom, pt (above the composer)")
    ap.add_argument("--left", type=float, default=0, help="band left, pt")
    ap.add_argument("--width", type=float, default=SCREEN_W, help="band width, pt (narrow = faster)")
    ap.add_argument("--jobs", type=int, default=2, help="OCR images at once")
    ap.add_argument("--json")
    ap.add_argument("--video-start", type=float, help="host epoch of video t=0, for row lag")
    ap.add_argument("--row-pt", type=float, default=16.0, help="terminal row pitch, pt (motion.py row_pitch_pt)")
    ap.add_argument("--drift-px", type=float, default=1.0, help="read-row drift threshold, video px")
    ap.add_argument("--pattern", help="regex whose group 1 is the row id (default `#%%07d`); e.g. '^(\\d{1,4})\\.' for a numbered list")
    ap.add_argument("--accurate", action="store_true", help="Vision accurate level (slower; worse on ids)")
    ap.add_argument("--keep", action="store_true", help="keep the extracted frames (path printed)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    d = tempfile.mkdtemp(prefix="tqrows-")
    try:
        k, fs = extract(a.video, a, d)
        if not fs:
            sys.exit("no frames decoded")
        res = ocr([os.path.join(d, f) for f in fs], k, a.jobs, a.accurate)
    finally:
        if a.keep:
            print("frames kept in", d)
        else:
            shutil.rmtree(d, ignore_errors=True)
    t0 = a.start or 0.0
    per = []
    for i, f in enumerate(fs):
        ids = parse(res.get(os.path.join(d, f), []), a.top, a.left, re.compile(a.pattern) if a.pattern else None)
        rec = {"i": i, "t": round(t0 + i / a.fps, 4), "n": len(ids),
               "window": [min(ids), max(ids)] if ids else None,
               "ids": {str(n): v[0] for n, v in sorted(ids.items())},
               "breaks": breaks_in(ids)}
        rec["_ids"] = ids
        per.append(rec)

    drift_pt = a.drift_px / k
    # Row pitch (pt): median y step between ids one apart, over all frames.
    steps = sorted(r2[0] - r1[0] for r in per for (r1, r2) in
                   zip(*(lambda rs: (rs, rs[1:]))(sorted((v[0], n) for n, v in r["_ids"].items())))
                   if r2[1] - r1[1] == 1)
    pitch = steps[len(steps) // 2] if steps else None
    # Scroll position per frame (rows): median over ids of id - y / pitch (robust to OCR misses).
    for r in per:
        vals = sorted(n - v[0] / pitch for n, v in r["_ids"].items()) if pitch else []
        r["pos"] = round(vals[len(vals) // 2], 3) if vals else None
    first_seen, lags = {}, []
    for i, r in enumerate(per):
        ids = r["_ids"]
        for n, (y, ms, _) in ids.items():
            if n not in first_seen:
                first_seen[n] = r["t"]
                if a.video_start and ms and r["window"] and n == r["window"][1]:
                    lags.append(round(a.video_start + r["t"] - ms / 1000.0, 3))
        if i == 0:
            continue
        p = per[i - 1]
        common = sorted(set(ids) & set(p["_ids"]))
        dys = sorted(ids[n][0] - p["_ids"][n][0] for n in common)
        r["dy_pt"] = round(dys[len(dys) // 2], 2) if dys else None
        # Same window: the content moved less than half a row (no row scrolled in or out).
        r["same_window"] = len(common) >= 3 and abs(r["dy_pt"]) < a.row_pt / 2
        if r["same_window"]:
            r["drift"] = abs(r["dy_pt"]) > drift_pt
    ov = lambda u, v: u[0] <= v[1] and v[0] <= u[1]
    for i in range(1, len(per) - 1):
        a_, b_, c_ = per[i - 1], per[i], per[i + 1]
        if not (a_["window"] and b_["window"] and c_["window"]):
            continue
        if ov(a_["window"], c_["window"]) and not ov(a_["window"], b_["window"]) and not ov(b_["window"], c_["window"]):
            per[i]["foreign"] = "disjoint"
            continue
        # Bounce: the content moves by >= half a terminal row and straight back the next frame
        # (a one-frame jump). Content moving down then up while following is a backstep.
        d1, d2 = b_.get("dy_pt"), c_.get("dy_pt")
        if d1 is not None and d2 is not None and d1 * d2 < 0 and min(abs(d1), abs(d2)) >= a.row_pt / 2:
            per[i]["bounce"] = round(d1 / a.row_pt, 2)
            if d1 > 0:
                per[i]["backstep"] = int(round(d1 / a.row_pt))
    for r in per:
        if r["breaks"] and "foreign" not in r:
            r["foreign"] = "break"

    seen = [r for r in per if r["window"]]
    summary = {
        "video": a.video, "fps": a.fps, "start": t0, "frames": len(per), "frames_with_ids": len(seen),
        "band_pt": [a.left, a.top, a.width, a.bottom - a.top], "row_pt": a.row_pt,
        "id_min": min((r["window"][0] for r in seen), default=None),
        "id_max": max((r["window"][1] for r in seen), default=None),
        "first_window": seen[0]["window"] if seen else None, "last_window": seen[-1]["window"] if seen else None,
        "foreign_frames": [{"t": r["t"], "why": r["foreign"], "window": r["window"], "breaks": r["breaks"]}
                           for r in per if r.get("foreign")],
        "backsteps": [{"t": r["t"], "rows": r["backstep"], "window": r["window"]} for r in per if r.get("backstep")],
        "bounces": [{"t": r["t"], "rows": r["bounce"], "window": r["window"]} for r in per if r.get("bounce")],
        "id_pitch_pt": pitch, "same_window_pairs": sum(1 for r in per if r.get("same_window")),
        "drift_frames": [{"t": r["t"], "dy_pt": r["dy_pt"], "dy_px": round(r["dy_pt"] * k, 1)}
                         for r in per if r.get("drift")],
        "max_read_drift_px": round(max((abs(r["dy_pt"]) for r in per if r.get("same_window") and r.get("dy_pt") is not None),
                                       default=0) * k, 1),
        "rows_seen": len(first_seen),
    }
    if lags:
        s = sorted(lags)
        summary["lag_s"] = {"n": len(s), "p50": s[len(s) // 2], "p95": s[min(len(s) - 1, int(len(s) * 0.95))], "max": s[-1]}
    for r in per:
        r.pop("_ids")
    if not a.quiet:
        for r in per:
            flag = (" FOREIGN(%s)" % r["foreign"] if r.get("foreign") else "") + \
                   (" BACKSTEP %d" % r["backstep"] if r.get("backstep") else "") + (" DRIFT" if r.get("drift") else "")
            print(f"{r['t']:8.2f}s  ids {r['n']:3d}  window {r['window']}  dy {r.get('dy_pt')}{flag}"
                  + (f"  breaks {r['breaks'][:4]}" if r["breaks"] else ""))
    print(f"frames {len(per)} @ {a.fps} fps, {len(seen)} with ids; ids {summary['id_min']}..{summary['id_max']}; "
          f"foreign {len(summary['foreign_frames'])}: {[(f['t'], f['why']) for f in summary['foreign_frames'][:10]]}; "
          f"backsteps {len(summary['backsteps'])}: {[(b['t'], b['rows']) for b in summary['backsteps'][:10]]}; "
          f"bounces {len(summary['bounces'])}; drift frames {len(summary['drift_frames'])} "
          f"(max read drift {summary['max_read_drift_px']} px over {summary['same_window_pairs']} same-window pairs)"
          + (f"; lag p50 {summary['lag_s']['p50']} s p95 {summary['lag_s']['p95']} s" if lags else ""))
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"summary": summary, "frames": per}, f, indent=1)


if __name__ == "__main__":
    main()
