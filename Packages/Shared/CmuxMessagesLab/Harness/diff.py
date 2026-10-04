#!/usr/bin/env python3
"""Compare two differential-harness runs (catalyst against appkit-port).

usage: diff.py A_DIR B_DIR [--md OUT.md] [--json OUT.json] [--diffs DIR]

Each run directory holds meta.json, frames.ndjson (one presented layer tree per
120 Hz tick) and png/ (CALayer.render captures at fixed times). For every
named transition the report gives, over the transition's frames, the largest
difference of any layer present in both runs:

- geometry: max of |dx|, |dy|, |dw|, |dh| of the window-space frame (pt)
- opacity, affine transform (a b c d, tx ty) and corner radius
- contentsScale and the backing bitmap's pixel size (equal or not)
- layers that are visible in only one run

and the pixel difference of the captures in the transition (mean absolute
difference per channel in 0-255, and the share of pixels off by more than 8).
"""
import json
import os
import sys

FIELDS = ["x", "y", "w", "h", "opacity", "a", "b", "c", "d", "tx", "ty", "cornerRadius",
          "contentsScale", "contentsPxW", "contentsPxH", "hidden"]
IX = {f: i for i, f in enumerate(FIELDS)}


def load(d):
    meta = json.load(open(os.path.join(d, "meta.json")))
    frames = {}
    with open(os.path.join(d, "frames.ndjson")) as f:
        for line in f:
            if not line.strip():
                continue
            o = json.loads(line)
            frames[round(o["t"] * 120)] = o["L"]
    return meta, frames


def compare_frame(la, lb):
    """Per-frame maxima over layers present (and visible) in both."""
    out = {"geo": (0.0, None), "opacity": (0.0, None), "transform": (0.0, None), "corner": (0.0, None),
           "scale": [], "px": [], "onlyA": [], "onlyB": []}
    for n, va in la.items():
        vb = lb.get(n)
        if vb is None:
            if va[IX["hidden"]] == 0 and va[IX["opacity"]] > 0.011:
                out["onlyA"].append(n)
            continue
        ha, hb = va[IX["hidden"]], vb[IX["hidden"]]
        if ha != hb:
            out["geo"] = max(out["geo"], (1e9, n + " (hidden in one)"), key=lambda p: p[0])
            continue
        if ha:
            continue
        g = max(abs(va[i] - vb[i]) for i in range(4))
        if g > out["geo"][0]:
            out["geo"] = (g, n)
        o = abs(va[IX["opacity"]] - vb[IX["opacity"]])
        if o > out["opacity"][0]:
            out["opacity"] = (o, n)
        tr = max(abs(va[IX[k]] - vb[IX[k]]) for k in ["a", "b", "c", "d", "tx", "ty"])
        if tr > out["transform"][0]:
            out["transform"] = (tr, n)
        c = abs(va[IX["cornerRadius"]] - vb[IX["cornerRadius"]])
        if c > out["corner"][0]:
            out["corner"] = (c, n)
        # contentsScale matters where a layer has a bitmap (outside a window
        # UIKit leaves view layers without contents at 1).
        has = va[IX["contentsPxW"]] > 0 or vb[IX["contentsPxW"]] > 0
        if has and va[IX["contentsScale"]] != vb[IX["contentsScale"]]:
            out["scale"].append((n, va[IX["contentsScale"]], vb[IX["contentsScale"]]))
        pa = (va[IX["contentsPxW"]], va[IX["contentsPxH"]])
        pb = (vb[IX["contentsPxW"]], vb[IX["contentsPxH"]])
        if (pa[0] or pb[0]) and pa != pb:
            out["px"].append((n, pa, pb))
    for n, vb in lb.items():
        if n not in la and vb[IX["hidden"]] == 0 and vb[IX["opacity"]] > 0.011:
            out["onlyB"].append(n)
    return out


def pixel_stats(pa, pb, diff_out=None):
    try:
        import numpy as np
        from PIL import Image
    except ImportError:
        return None
    a = np.asarray(Image.open(pa).convert("RGB")).astype(np.int16)
    b = np.asarray(Image.open(pb).convert("RGB")).astype(np.int16)
    if a.shape != b.shape:
        return {"mad": None, "shape": [list(a.shape), list(b.shape)]}
    d = np.abs(a - b)
    per = d.max(axis=2)
    res = {"mad": float(d.mean()), "bad8": float((per > 8).mean() * 100), "max": int(per.max())}
    if diff_out:
        Image.fromarray(np.clip(per * 8, 0, 255).astype("uint8")).save(diff_out)
    return res


def main():
    args = sys.argv[1:]
    a_dir, b_dir = args[0], args[1]
    md_out = args[args.index("--md") + 1] if "--md" in args else None
    js_out = args[args.index("--json") + 1] if "--json" in args else None
    diffs = args[args.index("--diffs") + 1] if "--diffs" in args else None
    if diffs:
        os.makedirs(diffs, exist_ok=True)
    meta_a, fa = load(a_dir)
    meta_b, fb = load(b_dir)
    ticks = sorted(set(fa) & set(fb))
    per_tick = {k: compare_frame(fa[k], fb[k]) for k in ticks}

    windows = [(e["name"], e["t"], e["t"] + e["duration"]) for e in meta_a["transitions"]]
    windows.append(("all frames", 0, meta_a["end"]))
    rows = []
    for name, t0, t1 in windows:
        ks = [k for k in ticks if t0 - 1e-9 <= k / 120 <= t1 + 1e-9]
        agg = {"geo": (0.0, None, None), "opacity": (0.0, None, None), "transform": (0.0, None, None), "corner": (0.0, None, None)}
        scale, px, only_a, only_b = set(), set(), set(), set()
        for k in ks:
            r = per_tick[k]
            for key in agg:
                if r[key][0] > agg[key][0]:
                    agg[key] = (r[key][0], r[key][1], k / 120)
            scale.update(n for n, _, _ in r["scale"])
            px.update(n for n, _, _ in r["px"])
            only_a.update(r["onlyA"])
            only_b.update(r["onlyB"])
        pix = []
        for t in meta_a.get("captures", []):
            if t0 - 1e-9 <= t <= t1 + 1e-9:
                fn = "t_%05d.png" % round(t * 1000)
                pa, pb = os.path.join(a_dir, "png", fn), os.path.join(b_dir, "png", fn)
                if os.path.exists(pa) and os.path.exists(pb):
                    s = pixel_stats(pa, pb, os.path.join(diffs, fn) if diffs else None)
                    if s and s.get("mad") is not None:
                        pix.append((t, s))
        rows.append({
            "transition": name, "frames": len(ks),
            "geoMaxPt": agg["geo"][0], "geoWorst": agg["geo"][1], "geoAt": agg["geo"][2],
            "opacityMax": agg["opacity"][0], "opacityWorst": agg["opacity"][1],
            "transformMax": agg["transform"][0], "transformWorst": agg["transform"][1],
            "cornerMax": agg["corner"][0],
            "contentsScaleMismatch": sorted(scale)[:20], "bitmapSizeMismatch": sorted(px)[:20],
            "onlyCatalyst": sorted(only_a)[:20], "onlyAppKit": sorted(only_b)[:20],
            "pixelMadMean": (sum(s["mad"] for _, s in pix) / len(pix)) if pix else None,
            "pixelMadMax": max((s["mad"] for _, s in pix), default=None),
            "pixelBad8Max": max((s["bad8"] for _, s in pix), default=None),
            "captures": len(pix),
        })

    def f(v, nd=2):
        return "-" if v is None else (("%." + str(nd) + "f") % v if v < 1e8 else "hidden")

    lines = ["| transition | frames | geometry max (pt) | worst layer | opacity max | transform max | scale/px mismatches | only in one | pixel mad mean / max | >8 levels max % |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for r in rows:
        lines.append("| %s | %d | %s | %s | %s | %s | %d / %d | %d / %d | %s / %s | %s |" % (
            r["transition"], r["frames"], f(r["geoMaxPt"], 3), (r["geoWorst"] or "")[:60], f(r["opacityMax"], 3),
            f(r["transformMax"], 4), len(r["contentsScaleMismatch"]), len(r["bitmapSizeMismatch"]),
            len(r["onlyCatalyst"]), len(r["onlyAppKit"]), f(r["pixelMadMean"]), f(r["pixelMadMax"]), f(r["pixelBad8Max"])))
    md = "\n".join(lines)
    print(md)
    if md_out:
        open(md_out, "w").write(md + "\n")
    if js_out:
        json.dump(rows, open(js_out, "w"), indent=1)


if __name__ == "__main__":
    main()
