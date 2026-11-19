#!/usr/bin/env python3
"""Scratch: an SVG specimen, Newsreader (opsz 12, wght 400) above Quillet Serif (wght 400), upright and italic,
plus a large detail of a few letters so the softened corners show. specimen.py OUT_DIR"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
from fontTools.pens.svgPathPen import SVGPathPen  # noqa: E402
from fontTools.pens.transformPen import TransformPen  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402
from fontTools.varLib import instancer  # noqa: E402

TEXT = [
    "The agent read 12 files and changed 3: a quiet, bookish reply.",
    "Hamburgefonstiv quick brown fox jumps over 1,284 lazy dogs.",
]
DETAIL = "nhaegry&R"


def line(font, text, x, y, size, out, fill):
    gs = font.getGlyphSet()
    cmap = font.getBestCmap()
    upm = font["head"].unitsPerEm
    s = size / upm
    for ch in text:
        name = cmap.get(ord(ch))
        if name is None:
            continue
        pen = SVGPathPen(gs)
        gs[name].draw(TransformPen(pen, (s, 0, 0, -s, x, y)))
        d = pen.getCommands()
        if d:
            out.append(f'<path d="{d}" fill="{fill}"/>')
        x += gs[name].width * s
    return x


def main():
    outdir = Path(sys.argv[1])
    parts = []
    y = 40
    for key, src, built in (("upright", "Newsreader[opsz,wght].ttf", "quillet-serif.woff2"),
                            ("italic", "Newsreader-Italic[opsz,wght].ttf", "quillet-serif-italic.woff2")):
        before = instancer.instantiateVariableFont(common.source(src), {"opsz": 12, "wght": 400})
        after = instancer.instantiateVariableFont(TTFont(outdir / built), {"wght": 400})
        for label, font, color in (("Newsreader opsz 12", before, "#666"), ("Quillet Serif", after, "#111")):
            parts.append(f'<text x="20" y="{y - 22}" font-family="sans-serif" font-size="12" fill="#a33">{label} ({key}), 30 px</text>')
            for t in TEXT:
                line(font, t, 20, y, 30, parts, color)
                y += 48
            y += 24
        for label, font, color in (("Newsreader", before, "#666"), ("Quillet", after, "#111")):
            parts.append(f'<text x="20" y="{y - 10}" font-family="sans-serif" font-size="12" fill="#a33">{label} detail, 160 px</text>')
            line(font, DETAIL, 20, y + 150, 160, parts, color)
            y += 230
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="{y}" viewBox="0 0 1500 {y}"><rect width="100%" height="100%" fill="#fbf8f1"/>' + "".join(parts) + "</svg>"
    (outdir / "specimen.svg").write_text(svg)


main()
