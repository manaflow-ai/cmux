"""Checks the built Quillet Sans files: reopen, gvar point counts, instances at wght min/default/max draw every
glyph, Il1 distinct, point counts before/after. Prints VERIFY lines; exits 1 on any failure."""
import io, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.varLib import instancer

out = Path(sys.argv[1])
fail = []
result = {}
for src, stem in [("HankenGrotesk[wght].ttf", "quillet-sans"), ("HankenGrotesk-Italic[wght].ttf", "quillet-sans-italic")]:
    data = (out / f"{stem}.woff2").read_bytes()
    font = TTFont(io.BytesIO(data))
    font.flavor = None
    buf = io.BytesIO(); font.save(buf); buf.seek(0)
    font = TTFont(buf)
    r = {"woff2_bytes": len(data), "glyphs": len(font.getGlyphOrder())}
    glyf, gvar = font["glyf"], font["gvar"]
    bad = []
    for name in font.getGlyphOrder():
        g = glyf[name]
        n = (len(g.components) if g.isComposite() else (len(g.coordinates) if g.numberOfContours > 0 else 0)) + 4
        for v in gvar.variations.get(name, []):
            if len(v.coordinates) != n:
                bad.append(name)
    if bad:
        fail.append(f"{stem}: gvar point count mismatch {bad[:10]}")
    r["gvar_mismatch"] = len(bad)
    axis = font["fvar"].axes[0]
    inst = {}
    for label, value in [("min", axis.minValue), ("default", axis.defaultValue), ("max", axis.maxValue)]:
        f2 = TTFont(io.BytesIO(buf.getvalue()))
        static = instancer.instantiateVariableFont(f2, {"wght": value})
        gs = static.getGlyphSet()
        errors = []
        for name in static.getGlyphOrder():
            try:
                gs[name].draw(BoundsPen(gs))
            except Exception as e:  # noqa: BLE001
                errors.append(f"{name}: {e}")
        b = io.BytesIO(); static.save(b)
        inst[label] = {"wght": value, "errors": len(errors), "bytes": len(b.getvalue()), "x_yMax": common.measured(static, "x"), "I_stem": common.measured(static, "I", "xMax") - common.measured(static, "I", "xMin")}
        if errors:
            fail.append(f"{stem} wght={value}: {errors[:5]}")
    r["instances"] = inst
    cmap = font.getBestCmap()
    gs = font.getGlyphSet()

    def outline(ch):
        p = DecomposingRecordingPen(gs); gs[cmap[ord(ch)]].draw(p); return p.value

    names = {c: cmap[ord(c)] for c in "Il1agtry"}
    r["cmap_names"] = names
    if len({repr(outline(c)) for c in "Il1"}) != 3 or len({names[c] for c in "Il1"}) != 3:
        fail.append(f"{stem}: I l 1 not distinct")
    src_font = common.source(src)
    sc = src_font.getBestCmap()

    def pts(f, name):
        g = f["glyf"][name]
        return "composite" if g.isComposite() else len(g.coordinates)

    r["points"] = {c: {"before": f"{sc[ord(c)]}:{pts(src_font, sc[ord(c)])}", "after": f"{cmap[ord(c)]}:{pts(font, cmap[ord(c)])}"} for c in "aglt r".replace(" ", "")}
    r["reach"] = {tag: {c: common.feature_mapping(font, [tag]).get(cmap[ord(c)], "-") for c in "gi."} for tag in ("ss01", "ss02", "ss03")}
    r["names"] = {i: font["name"].getDebugName(i) for i in (0, 1, 2, 4, 6, 16, 17)}
    result[stem] = r
print("VERIFY " + json.dumps({"ok": not fail, "fail": fail, "faces": result}))
sys.exit(1 if fail else 0)
