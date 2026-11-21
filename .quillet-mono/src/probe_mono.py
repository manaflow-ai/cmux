"""Probe JetBrains Mono: metrics, masters, GSUB features and their glyphs, sizes with and without calt."""
import io, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

out = {}
for name in ["JetBrainsMono[wght].ttf", "JetBrainsMono-Italic[wght].ttf"]:
    f = common.source(name)
    info = common.report(f)
    info["sxHeight"] = f["OS/2"].sxHeight
    info["typo"] = [f["OS/2"].sTypoAscender, f["OS/2"].sTypoDescender, f["OS/2"].sTypoLineGap]
    info["tables"] = sorted(f.keys())
    peaks = set()
    for vs in f["gvar"].variations.values():
        for v in vs:
            peaks.add(tuple(sorted((t, tuple(round(x, 3) for x in p)) for t, p in v.axes.items())))
    info["peaks"] = sorted(peaks)
    gsub = f["GSUB"].table
    feats = {}
    for r in gsub.FeatureList.FeatureRecord:
        m = common.feature_mapping(f, [r.FeatureTag])
        types = sorted({gsub.LookupList.Lookup[i].LookupType for i in r.Feature.LookupListIndex})
        feats.setdefault(r.FeatureTag, {"types": types, "n": len(m), "map": sorted(f"{a}>{b}" for a, b in m.items())[:40]})
    info["features"] = feats
    adv = {}
    for g, (a, _) in f["hmtx"].metrics.items():
        adv[a] = adv.get(a, 0) + 1
    info["advances"] = adv
    cmap = f.getBestCmap()
    glyf = f["glyf"]
    info["pts"] = {c: (len(glyf[cmap[ord(c)]].coordinates) if not glyf[cmap[ord(c)]].isComposite() else "comp") for c in "0agflr"}
    info["overlap_flag_first_point"] = sum(1 for g in f.getGlyphOrder() if glyf[g].numberOfContours > 0 and glyf[g].flags[0] & 0x40)
    info["simple_glyphs"] = sum(1 for g in f.getGlyphOrder() if glyf[g].numberOfContours > 0)
    def size(drop=()):
        ff = common.source(name)
        common.subset(ff, drop_features=drop)
        ff.flavor = "woff2"
        b = io.BytesIO(); ff.save(b); return len(b.getvalue()), len(ff.getGlyphOrder())
    info["woff2_latin"] = size()
    info["woff2_latin_no_calt"] = size(["calt"])
    out[name] = info
print("PROBE " + json.dumps(out, default=str))
