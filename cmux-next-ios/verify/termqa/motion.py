"""Frame-split motion analysis of a terminal recording (M-MOTION, M-BLACK, M-TOUCH;
ACCEPTANCE.md section 2, gap G-02): numbers instead of eyeballing.

    python3 motion.py VIDEO [--fps 60] [--start S] [--dur D] [--top 70] [--bottom 0.55]
                            [--crop x,y,w,h] [--width 402] [--json OUT] [--quiet]
                            [--touch LOG --video-start EPOCH]

Band: points from --top to --bottom*874 (keep it above the composer/keyboard), or
--crop x,y,w,h in points (402x874 space) for a grid card or a tab-label band.
--width is the analysis width in px of the whole screen: 402 (default) makes 1 px = 1 pt;
1206 analyses the simulator recording at full resolution (1 px drift precision, slower).

Per frame: the vertical shift of the band against the previous frame (s > 0: content
moved down), its residual and a confidence; the lit fraction (M-BLACK); flashes (up to
~33 ms of frames, i.e. 1 frame at 30 fps, 2 at 60, unlike both neighbours while the
neighbours are alike), classed "jump" (the neighbour shifted by N px for one frame) or
"foreign" (other content). Summary: row pitch
(calibrated from the band's row-intensity autocorrelation), moves, reversals (a move
followed within 0.5 s by one of the opposite sign), black frames, effective source fps
(fraction of source frame gaps > 34 ms; > 2 % marks the window invalid), and with
--touch, finger-driven vs spontaneous moves and reversals.

Touch log: json lines {"t": host_epoch_s, "kind": "drag|tap|swipe|key", "dur": s?} (or
"t_end"); video time = t - --video-start. A move is finger-driven when it falls inside
[t, t + dur + 0.6 s] of some gesture (0.6 s deceleration tail).
"""
import argparse
import json
import subprocess
import sys

import numpy as np

SCREEN_W, SCREEN_H = 402, 874           # points
BLACK_LIT = 60                          # luma above which a pixel is lit
BLACK_FRAC = 0.004                      # < 0.4 % lit = black (section 0)
TAIL = 0.6                              # finger deceleration tail, s
DEFAULT_DUR = {"tap": 0.1, "key": 0.1, "drag": 0.5, "swipe": 0.3}


def probe(video):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height", "-of", "csv=p=0", video],
                         capture_output=True, text=True, check=True).stdout.strip().split(",")
    return int(out[0]), int(out[1])


def source_fps_check(video, start, dur):
    """Fraction of source frame gaps > 34 ms inside the window (ffprobe pts)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "packet=pts_time", "-of", "csv=p=0", video],
                         capture_output=True, text=True, check=True).stdout.split()
    ts = sorted(float(x.strip(",")) for x in out if x.strip(",") not in ("", "N/A"))
    lo = start or 0.0
    hi = lo + dur if dur else float("inf")
    ts = [t for t in ts if lo <= t <= hi]
    gaps = np.diff(ts) if len(ts) > 1 else np.array([])
    long_ = int((gaps > 0.034).sum())
    frac = long_ / len(gaps) if len(gaps) else 1.0
    return {"source_frames": len(ts), "gaps_over_34ms": long_, "frac_gaps_over_34ms": round(frac, 4),
            "max_gap_ms": round(float(gaps.max()) * 1000, 1) if len(gaps) else None,
            "effective_fps": round((len(ts) - 1) / (ts[-1] - ts[0]), 1) if len(ts) > 1 and ts[-1] > ts[0] else 0,
            "valid": frac < 0.02}


def frames(video, fps, start, dur, width):
    """Yield gray uint8 frames (width x height) from an ffmpeg pipe."""
    vw, vh = probe(video)
    height = int(round(vh * width / vw / 2)) * 2
    cmd = ["ffmpeg", "-v", "error"] + (["-ss", str(start)] if start else []) + (["-t", str(dur)] if dur else []) + \
          ["-i", video, "-vf", f"fps={fps},scale={width}:{height},format=gray", "-f", "rawvideo", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    n = width * height
    while True:
        buf = p.stdout.read(n)
        if len(buf) < n:
            break
        yield np.frombuffer(buf, dtype=np.uint8).reshape(height, width)
    p.wait()


def band_slice(a, args, k):
    h, w = a.shape
    if args.crop:
        x, y, cw, ch = args.crop
        return a[int(y * k):int((y + ch) * k), int(x * k):int((x + cw) * k)]
    return a[int(args.top * k):int(args.bottom * SCREEN_H * k), :]


def residuals(p, c, lo, hi):
    n = len(p)
    out = {}
    for s in range(lo, hi + 1):
        if s >= 0:
            a, b = c[s:], p[:n - s]
        else:
            a, b = c[:n + s], p[-s:]
        if len(a) < n // 2:
            continue
        out[s] = float(np.mean(np.abs(a - b)))
    return out


def shift(p, c, maxs, k, row):
    """Best vertical shift s (c[y] ~ p[y - s]) with tie-break and confidence.

    Coarse search at 1 pt resolution, refine at full resolution. Among the local minima
    whose residual is within 5 % of the best, prefer the smallest |s| (periodic text).
    Confidence = 1 - r_chosen / r_alt, r_alt the best residual farther than half a row."""
    if k > 1:
        m = len(p) // k * k
        pc, cc = p[:m].reshape(-1, k).mean(1), c[:m].reshape(-1, k).mean(1)
        coarse = residuals(pc, cc, -int(maxs / k), int(maxs / k))
        cands = [s * k for s in local_minima(coarse, 1.05)]
        res = {}
        for s0 in cands:
            res.update(residuals(p, c, s0 - k, s0 + k))
    else:
        res = residuals(p, c, -maxs, maxs)
    mins = local_minima(res, 1.05)
    s = min(mins, key=lambda x: (abs(x), x))
    r = res[s]
    r0 = res.get(0)
    if r0 is None:
        r0 = residuals(p, c, 0, 0)[0]
    far = [v for x, v in res.items() if abs(x - s) > row / 2]
    if k > 1:
        far += [v for x, v in coarse.items() if abs(x * k - s) > row / 2]
    alt = min(far) if far else r0
    conf = 0.0 if alt <= 0 else max(0.0, 1 - r / alt)
    return s, r, r0, conf


def local_minima(res, tol):
    ks = sorted(res)
    best = min(res.values())
    out = []
    for i, s in enumerate(ks):
        v = res[s]
        if v > best * tol + 1e-6:
            continue
        left = res[ks[i - 1]] if i > 0 else float("inf")
        right = res[ks[i + 1]] if i + 1 < len(ks) else float("inf")
        if v <= left and v <= right:
            out.append(s)
    return out or [min(res, key=res.get)]


def row_pitch(profiles, k):
    """Row pitch in analysis px from the row-intensity autocorrelation (median over frames)."""
    lo, hi = int(8 * k), int(40 * k)
    est = []
    for p in profiles:
        x = p - p.mean()
        if x.std() < 1:
            continue
        ac = np.correlate(x, x, "full")[len(x) - 1:]
        ac = ac / ac[0]
        seg = ac[lo:hi]
        i = int(np.argmax(seg))
        if seg[i] > 0.2 and 0 < i < len(seg) - 1:
            # parabolic refinement
            y0, y1, y2 = seg[i - 1], seg[i], seg[i + 1]
            d = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2) if (y0 - 2 * y1 + y2) != 0 else 0
            est.append(lo + i + d)
    if not est:
        return None, 0
    return float(np.median(est)), len(est)


def load_touch(path, video_start):
    wins = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        t = float(e["t"]) - video_start
        kind = e.get("kind", "tap")
        if "t_end" in e:
            end = float(e["t_end"]) - video_start
        else:
            end = t + float(e.get("dur", DEFAULT_DUR.get(kind, 0.3)))
        wins.append((t, end + TAIL, kind))
    return sorted(wins)


def finger_at(t, wins):
    for a, b, kind in wins:
        if a <= t <= b:
            return kind
    return None


def reversals(moves, min_shift):
    rev = []
    for i, m in enumerate(moves):
        for m2 in moves[i + 1:]:
            if m2["t"] - m["t"] > 0.5:
                break
            if m["shift_px"] * m2["shift_px"] < 0 and abs(m["shift_px"]) >= min_shift and abs(m2["shift_px"]) >= min_shift:
                rev.append({"t": m["t"], "shift_px": m["shift_px"], "t2": m2["t"], "shift2_px": m2["shift_px"],
                            "spontaneous": not m.get("finger") and not m2.get("finger")})
                break
    return rev


def main():
    ap = argparse.ArgumentParser(description="terminal band motion, flashes, black frames (M-MOTION/M-BLACK/M-TOUCH)")
    ap.add_argument("video")
    ap.add_argument("--fps", type=int, default=60)
    ap.add_argument("--start", type=float)
    ap.add_argument("--dur", type=float)
    ap.add_argument("--top", type=float, default=70, help="band top, pt")
    ap.add_argument("--bottom", type=float, default=0.55, help="band bottom, fraction of 874 pt")
    ap.add_argument("--crop", help="x,y,w,h in points (402x874); overrides --top/--bottom")
    ap.add_argument("--width", type=int, default=402, help="analysis width px (402 = pt, 1206 = full res)")
    ap.add_argument("--json", help="write per-frame results and summary here")
    ap.add_argument("--touch", help="gesture log, json lines {t, kind, dur?}")
    ap.add_argument("--video-start", type=float, help="host epoch of video t=0 (needed with --touch)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    if a.crop:
        a.crop = [float(v) for v in a.crop.split(",")]
        assert len(a.crop) == 4, "--crop x,y,w,h"
    if a.touch and a.video_start is None:
        ap.error("--touch needs --video-start")
    k = a.width / SCREEN_W                       # analysis px per pt
    vw, _ = probe(a.video)
    px_per_apx = vw / a.width                    # video px per analysis px
    wins = load_touch(a.touch, a.video_start) if a.touch else None
    t0 = a.start or 0.0

    per, bands, profiles = [], [], []
    hist = []                                    # last 5 bands (float32) for flash test
    for i, fr in enumerate(frames(a.video, a.fps, a.start, a.dur, a.width)):
        b = band_slice(fr, a, k)
        lit = float((b > BLACK_LIT).mean())
        bf = b.astype(np.float32)
        prof = bf.mean(axis=1)
        rec = {"i": i, "t": round(t0 + i / a.fps, 4), "lit": round(lit, 5)}
        if i % 10 == 0:
            profiles.append(prof)
        if bands:
            p_prev = bands[-1]
            s, r, r0, conf = shift(p_prev, prof, int(120 * k), int(round(k)), 16 * k)
            rec.update({"shift_apx": s, "resid": round(r, 2), "resid0": round(r0, 2), "conf": round(conf, 3),
                        "diff": round(float(np.mean(np.abs(bf - hist[-1]))), 2)})
        bands = (bands + [prof])[-2:]
        hist = (hist + [bf])[-5:]
        per.append(rec)
        # Flash ending before frame i: frames j..i-1 (1-3 frames) unlike j-1, while j-1 ~ i.
        for L in range(1, max(1, round(a.fps / 30)) + 1):     # a flash lasts at most ~33 ms
            if len(hist) < L + 2:
                break
            before, after = hist[-(L + 2)], hist[-1]
            inner = hist[-(L + 1):-1]
            d_in = [float(np.mean(np.abs(x - before))) for x in inner]
            nb = float(np.mean(np.abs(after - before)))
            if min(d_in) > 12 and nb < min(d_in) * 0.35:
                j = i - L
                if "flash" not in per[j] and "flash_cont" not in per[j] and "flash" not in per[j - 1]:
                    # kind: "jump" when the odd frame is the neighbour shifted by whole px (a one-frame
                    # jump of N rows, T-FOLLOW-03), "foreign" otherwise (other content, T-SCROLL-02).
                    fs, fr, _, _ = shift(before.mean(axis=1), inner[0].mean(axis=1), int(120 * k), int(round(k)), 16 * k)
                    kind = "jump" if fs != 0 and fr < 0.35 * float(np.mean(np.abs(before.mean(axis=1) - inner[0].mean(axis=1)))) else "foreign"
                    per[j]["flash"] = {"frames": L, "kind": kind, "jump_pt": round(fs / k, 1) if kind == "jump" else None,
                                       "diff_prev": round(min(d_in), 1), "prev_to_next": round(nb, 1)}
                    for jj in range(j + 1, j + L):
                        per[jj]["flash_cont"] = True
                break
    if not per:
        sys.exit("no frames decoded")

    row, nrow = row_pitch(profiles, k)
    row_pt = row / k if row else None
    for rec in per:
        if "shift_apx" in rec:
            s = rec.pop("shift_apx")
            rec["shift_pt"] = round(s / k, 2)
            rec["shift_px"] = round(s * px_per_apx, 1)
            rec["shift_rows"] = round(s / row, 3) if row else None
            rec["move"] = s != 0 and rec["resid"] < rec["resid0"] * 0.7
            if wins is not None:
                rec["finger"] = finger_at(rec["t"] - 0.5 / a.fps, wins)

    lits = np.array([r["lit"] for r in per])
    med = float(np.median(lits))
    content = med >= BLACK_FRAC * 4
    black = [r for r in per if content and r["lit"] < BLACK_FRAC]
    for r in black:
        r["black"] = True
    runs = []
    for r in black:
        if runs and r["i"] == runs[-1]["last_i"] + 1:
            runs[-1].update({"end": r["t"], "last_i": r["i"], "frames": runs[-1]["frames"] + 1})
        else:
            runs.append({"start": r["t"], "end": r["t"], "first_i": r["i"], "last_i": r["i"], "frames": 1})

    moves = [r for r in per if r.get("move")]
    rev = reversals(moves, 4 * px_per_apx * k)
    flashes = [{"t": r["t"], **r["flash"]} for r in per if "flash" in r]
    src = source_fps_check(a.video, a.start, a.dur)
    summary = {
        "video": a.video, "fps": a.fps, "start": t0, "frames": len(per), "analysis_width": a.width,
        "band_pt": a.crop if a.crop else [0, a.top, SCREEN_W, a.bottom * SCREEN_H - a.top],
        "row_pitch_pt": round(row_pt, 2) if row_pt else None,
        "row_pitch_px": round(row * px_per_apx, 1) if row else None, "row_pitch_samples": nrow,
        "moves": len(moves), "moves_down": sum(1 for m in moves if m["shift_px"] > 0),
        "moves_up": sum(1 for m in moves if m["shift_px"] < 0),
        "max_move_rows": max((abs(m["shift_rows"] or 0) for m in moves), default=0),
        "low_confidence_moves": sum(1 for m in moves if m["conf"] < 0.1),
        "reversals": len(rev), "reversal_list": rev,
        "flashes": len(flashes), "flashes_foreign": sum(1 for f in flashes if f["kind"] == "foreign"),
        "flashes_jump": sum(1 for f in flashes if f["kind"] == "jump"), "flash_list": flashes,
        "lit_median": round(med, 5), "black_frames": len(black), "black_runs": runs,
        "black_times": [r["t"] for r in black],
        "source": src, "valid": src["valid"],
    }
    if wins is not None:
        sp = [m for m in moves if not m["finger"]]
        summary.update({"gestures": len(wins), "finger_moves": len(moves) - len(sp), "spontaneous_moves": len(sp),
                        "spontaneous_moves_down": sum(1 for m in sp if m["shift_px"] > 0),
                        "spontaneous_moves_list": [{"t": m["t"], "shift_rows": m["shift_rows"], "shift_px": m["shift_px"]}
                                                   for m in sp][:200],
                        "spontaneous_reversals": sum(1 for r in rev if r["spontaneous"])})

    if not a.quiet:
        for r in per:
            if r.get("move"):
                tag = "" if wins is None else ("  finger:" + r["finger"] if r["finger"] else "  SPONTANEOUS")
                print(f"{r['t']:8.2f}s  shift {r['shift_pt']:+6.1f}pt {r['shift_px']:+7.1f}px "
                      f"{(r['shift_rows'] or 0):+5.2f}rows  (resid {r['resid']:.1f} vs {r['resid0']:.1f}, conf {r['conf']:.2f}){tag}")
    for f in flashes:
        print(f"{f['t']:8.2f}s  FLASH  {f['kind']}{'' if f['jump_pt'] is None else ' %+.0fpt' % f['jump_pt']} {f['frames']} frame(s), diff to prev {f['diff_prev']:.1f}, prev-to-next {f['prev_to_next']:.1f}")
    for run in runs:
        print(f"{run['start']:8.2f}s  BLACK  {run['frames']} frame(s) to {run['end']:.2f}s")
    print(f"frames {len(per)} @ {a.fps} fps; row {summary['row_pitch_pt']} pt ({summary['row_pitch_px']} px); "
          f"moves {len(moves)}; reversals {len(rev)}: {[(r['t'], r['shift_px'], r['t2'], r['shift2_px']) for r in rev[:12]]}; "
          f"flashes {len(flashes)}: {[(f['t'], f['frames']) for f in flashes[:12]]}; black {len(black)} in {len(runs)} run(s); "
          f"source {src['effective_fps']} fps, gaps>34ms {src['frac_gaps_over_34ms'] * 100:.1f}% ({'valid' if src['valid'] else 'INVALID'})"
          + (f"; spontaneous moves {summary['spontaneous_moves']}, spontaneous reversals {summary['spontaneous_reversals']}"
             if wins is not None else ""))
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"summary": summary, "frames": per}, f, indent=1)


if __name__ == "__main__":
    main()
