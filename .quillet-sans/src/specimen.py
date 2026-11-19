"""Draws an SVG specimen (no shaping: cmap + advances; features by a glyph-name mapping) of fonts at weights.
usage: specimen.py OUT.svg LABEL=FONT[@feat,feat] ...  (fonts may be woff2)"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import common
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.varLib import instancer

TEXTS = [(96, "agIl1t rfjy"), (40, "Il1 illegal agility, quill 0O"), (40, "The agent read 12 files."), (40, "HOMERUN gaze vwkx AVW")]
WEIGHTS = [100, 400, 900]
out, specs = sys.argv[1], sys.argv[2:]
parts, y = [], 0
for spec in specs:
    label, rest = spec.split("=", 1)
    path, _, feats = rest.partition("@")
    for w in WEIGHTS:
        font = instancer.instantiateVariableFont(TTFont(path), {"wght": w})
        mapping = common.feature_mapping(font, feats.split(",")) if feats else {}
        cmap, gs, hmtx = font.getBestCmap(), font.getGlyphSet(), font["hmtx"]
        y += 30
        parts.append(f'<text x="10" y="{y}" font-size="18" fill="#888">{label} wght {w}</text>')
        for size, text in TEXTS:
            y += size * 1.25
            x = 10.0
            s = size / 1000
            for ch in text:
                name = cmap.get(ord(ch))
                if name is None:
                    continue
                name = mapping.get(name, name)
                pen = SVGPathPen(gs)
                gs[name].draw(TransformPen(pen, (s, 0, 0, -s, x, y)))
                d = pen.getCommands()
                if d:
                    parts.append(f'<path d="{d}"/>')
                x += hmtx[name][0] * s
height = y + 30
Path(out).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="{height:.0f}" viewBox="0 0 1400 {height:.0f}"><rect width="100%" height="100%" fill="#fff"/><g fill="#111">' + "".join(parts) + "</g></svg>")
