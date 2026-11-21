import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common
from fontTools.pens.svgPathPen import SVGPathPen
out = {}
for name in ["HankenGrotesk[wght].ttf", "HankenGrotesk-Italic[wght].ttf"]:
    f = common.source(name)
    info = common.report(f)
    os2 = f["OS/2"]
    info.update(sxHeight=os2.sxHeight, sCapHeight=os2.sCapHeight, typo=[os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap], hhea_full=[f["hhea"].ascent, f["hhea"].descent], winAD=[os2.usWinAscent, os2.usWinDescent], fsSel=os2.fsSelection)
    info["name"] = {r.nameID: r.toUnicode() for r in f["name"].names if r.platformID == 3}
    gsub = f["GSUB"].table
    feats = {}
    for rec in gsub.FeatureList.FeatureRecord:
        m = common.feature_mapping(f, [rec.FeatureTag])
        if rec.FeatureTag.startswith(("ss", "cv", "salt", "aalt", "zero", "case", "locl")) or len(m) < 40:
            feats.setdefault(rec.FeatureTag, sorted(f"{a}>{b}" for a, b in m.items()))
        else:
            feats.setdefault(rec.FeatureTag, [f"{len(m)} subs"])
        # feature params (ss names)
        p = rec.Feature.FeatureParams
        if p is not None and hasattr(p, "UINameID"):
            feats[rec.FeatureTag + "_name"] = [f["name"].getDebugName(p.UINameID)]
    info["features"] = feats
    info["lookup_types"] = sorted({l.LookupType for l in gsub.LookupList.Lookup})
    go = f.getGlyphOrder()
    info["alt_glyphs"] = [g for g in go if "." in g and g.split(".")[0] in list("aglyItjfr1Q") + ["one", "zero", "ampersand"]]
    cmap = f.getBestCmap()
    info["peaks"] = sorted({tuple(sorted((t, round(p[1], 3)) for t, p in v.axes.items())) for vs in f["gvar"].variations.values() for v in vs})
    gs = f.getGlyphSet()
    glyf = f["glyf"]
    dump = {}
    for g in ["a", "g", "l", "t", "r", "I", "one", "y", "i", "j", "f", "e", "c", "s", "n", "k", "v", "comma", "period"] + info["alt_glyphs"]:
        if g not in go: continue
        pen = SVGPathPen(gs)
        gs[g].draw(pen)
        gl = glyf[g]
        dump[g] = {"adv": f["hmtx"][g][0], "pts": (len(gl.coordinates) if not gl.isComposite() else "comp:" + ",".join(c.glyphName for c in gl.components)), "path": pen.getCommands()}
    info["glyphs"] = dump
    info["avg_lower_by_glyph"] = {c: f["hmtx"][cmap[ord(c)]][0] for c in "abcdefghijklmnopqrstuvwxyz"}
    info["H_I_sidebearings"] = {g: f["hmtx"][g] for g in ["H", "n", "o", "I", "l"]}
    info["kern_present"] = "GPOS" in f
    info["woff2_before"] = common.woff2_size_of_source_subset(name)
    out[name] = info
print("PROBE " + json.dumps(out, default=str))
