#!/usr/bin/env python3
"""Scratch: what Newsreader offers (axes, GSUB, alternates, metrics at several opsz)."""
import io, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common
from fontTools.varLib import instancer

out = {}
for name in ["Newsreader[opsz,wght].ttf", "Newsreader-Italic[opsz,wght].ttf"]:
    f = common.source(name)
    info = {}
    info["axes"] = {a.axisTag: [a.minValue, a.defaultValue, a.maxValue] for a in f["fvar"].axes}
    info["instances"] = [i.coordinates for i in f["fvar"].instances][:6]
    peaks = set()
    for vs in f["gvar"].variations.values():
        for v in vs:
            peaks.add(tuple(sorted((t, tuple(round(x, 3) for x in p)) for t, p in v.axes.items())))
    info["peaks"] = sorted(peaks)
    info["avar"] = {k: dict(v) for k, v in f["avar"].segments.items()} if "avar" in f else None
    info["tables"] = sorted(f.keys())
    info["os2"] = dict(x=f["OS/2"].sxHeight, cap=f["OS/2"].sCapHeight, typo=[f["OS/2"].sTypoAscender, f["OS/2"].sTypoDescender, f["OS/2"].sTypoLineGap],
                       win=[f["OS/2"].usWinAscent, f["OS/2"].usWinDescent], hhea=[f["hhea"].ascent, f["hhea"].descent, f["hhea"].lineGap])
    gsub = f["GSUB"].table
    feats = {}
    for rec in gsub.FeatureList.FeatureRecord:
        m = common.feature_mapping(f, [rec.FeatureTag])
        types = sorted({gsub.LookupList.Lookup[i].LookupType for i in rec.Feature.LookupListIndex})
        feats[rec.FeatureTag] = {"types": types, "n": len(m), "map": sorted(f"{a}>{b}" for a, b in m.items())[:40]}
    info["features"] = feats
    if "name" in f:
        info["featureNames"] = {}
        for rec in gsub.FeatureList.FeatureRecord:
            p = rec.Feature.FeatureParams
            if p is not None and hasattr(p, "UINameID"):
                info["featureNames"][rec.FeatureTag] = f["name"].getDebugName(p.UINameID)
    order = f.getGlyphOrder()
    info["alt_glyphs"] = [g for g in order if g.split(".")[0] in ("a", "g", "y", "ampersand", "Q", "R", "J", "k", "one", "zero", "f", "t", "e", "W") and "." in g]
    info["figure_glyphs"] = sorted({g.split(".", 1)[1] for g in order if g.startswith(("zero.", "one.", "two.")) })
    info["n_glyphs"] = len(order)
    info["cmap_latin_missing"] = [hex(c) for c in common.LATIN if c not in f.getBestCmap()]
    rows = {}
    for opsz in [6, 9, 10, 11, 12, 13, 14, 16, 18, 24, 72]:
        try:
            g = instancer.instantiateVariableFont(common.source(name), {"opsz": opsz, "wght": 400})
        except Exception as e:
            rows[opsz] = str(e); continue
        r = common.report(g)
        r.pop("axes")
        hm = g["hmtx"]; cm = g.getBestCmap()
        r["n_adv"] = hm[cm[ord("n")]][0]; r["o_adv"] = hm[cm[ord("o")]][0]
        r["n_lsb"] = hm[cm[ord("n")]][1]
        gl = g["glyf"]; n = gl[cm[ord("n")]]; n.recalcBounds(gl)
        r["n_ink"] = n.xMax - n.xMin
        # stem: horizontal run of l at mid-x-height
        l = gl[cm[ord("l")]]; l.recalcBounds(gl)
        r["l_ink"] = l.xMax - l.xMin
        r["H_adv"] = hm[cm[ord("H")]][0]
        rows[opsz] = r
    info["by_opsz_w400"] = rows
    pc = {}
    for c in "aegry":
        gn = f.getBestCmap()[ord(c)]
        gg = f["glyf"][gn]
        pc[c] = {"glyph": gn, "points": len(gg.coordinates) if not gg.isComposite() else "composite", "contours": gg.numberOfContours}
    info["points"] = pc
    out[name] = info
    for opsz in [10, 12, 14, 16]:
        info.setdefault("woff2_pinned", {})[opsz] = common.woff2_size_of_source_subset(name, pin={"opsz": opsz})
    info["woff2_full_latin"] = common.woff2_size_of_source_subset(name)
print("INSPECT-JSON " + json.dumps(out, default=str))
