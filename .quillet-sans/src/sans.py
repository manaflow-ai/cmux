#!/usr/bin/env python3
"""Builds Quillet Sans, the sans of the Quillet family, from Hanken Grotesk (SIL OFL 1.1, no Reserved Font Name).

The sans sets the cmux agent chat's interface (13-14 px), its composer and the user's own messages (15 px). Every
change is made by this code on Hanken Grotesk's own OFL outlines, through build/common.py, and each is written
down with its reason in docs/design-sans.md:

- x-height (X_HEIGHT): lowercase stretched to a little more of the em, so 13 px UI text reads a size up;
- default forms (DEFAULT_FEATURES): Hanken's own single-storey g and round dots drawn without a feature, the
  plain forms kept behind the same features;
- softer corners (SOFTEN): the sharp stroke ends and stem feet of letters and figures get a small round;
- tracking (TRACKING): a little more room between letters at 13-15 px;
- the shared Quillet line box (common.set_line_metrics) and the name.

    python3 build/sans.py --out fonts      writes fonts/quillet-sans.woff2, fonts/quillet-sans-italic.woff2
                                            and build/out/sans.json (the TTFs go to build/out/sans/)
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import common  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402

FAMILY = "Quillet Sans"
DESCRIPTION = (
    "Quillet Sans is the sans of Quillet, cmux's type family for the agent chat: a modified version of Hanken "
    "Grotesk under the SIL Open Font License 1.1, with a taller x-height, a single-storey g, round dots, "
    "softened stroke ends and slightly open spacing for interface text at 13-15 px."
)

# --- The design numbers (docs/design-sans.md says why) ---------------------------------------------------

X_HEIGHT = 512  # units of 1000; Hanken measures 493 (x/cap 0.707), its ascenders stop at the cap height (697)
TRACKING = 10  # units added to every advance, 5 each side: +0.15 px at 15 px, +0.13 px at 13 px
SOFTEN = {"fraction": 0.22, "cap": 18}  # radius = 22 % of the shorter edge at that master, at most 18 units
# Hanken's own forms made the default, in order (each step sees the cmap the previous one left):
# ss01 is the single-storey g (the upright's default g is the two-storey one; the italic's g is single-storey
# already, so the upright now matches it); ss03 is round dots (i j, accents' dots, . , : ; ! ? and friends).
DEFAULT_FEATURES = {
    "Regular": ["ss01", "ss03"],
    "Italic": ["ss03"],
}
# Corners that stay sharp although soften_corners would round them: the flat-cut vertices of the diagonal
# letters (the foot of v w y, the apex of A, the vertices of M V W), where a round reads as a blob, not a soft
# stroke end. Their other corners (stroke ends at the top of v, say) stay sharp with them, for one look per glyph.
SHARP = {"A", "M", "V", "W", "v", "w", "y"}

FACES = [
    ("HankenGrotesk[wght].ttf", "Regular", "quillet-sans"),
    ("HankenGrotesk-Italic[wght].ttf", "Italic", "quillet-sans-italic"),
]


def build(source_name: str, style: str, stem: str, out: Path, work: Path) -> dict:
    font = common.source(source_name)
    before = common.report(font)
    before_points = point_counts(font)
    changes = []

    # 1. Latin subset first, so every later edit touches only shipped glyphs. All layout features are kept.
    common.subset(font)

    # 2. x-height (italic: points move along the slant, common.set_x_height).
    xh = common.set_x_height(font, X_HEIGHT)
    changes.append({"change": "x-height", **xh})

    # 3. Default forms, the plain forms kept behind the same features.
    for tag in DEFAULT_FEATURES[style]:
        mapping = common.feature_mapping(font, [tag])
        if not mapping:
            raise SystemExit(f"{source_name}: no single substitutions in {tag}")
        swapped = common.make_default(font, mapping)
        # common.make_default also makes the feature swap back and keeps the other features working on the new form
        cmap = font.getBestCmap()
        back = {c: f"{cmap[ord(c)]}>{common.feature_mapping(font, [tag]).get(cmap[ord(c)], '-')}" for c in "gi." if ord(c) in cmap}
        changes.append({"change": "default forms", "feature": tag, "characters": "".join(swapped), "feature_now_gives": back})

    # 4. Softer corners.
    glyphs = soften_targets(font)
    rounded = common.soften_corners(font, glyphs, **SOFTEN)
    changes.append({"change": "soften corners", **SOFTEN, "glyphs": len(glyphs), "corners": rounded, "kept_sharp": sorted(SHARP)})

    # 5. Tracking (the same in every master: gvar and HVAR advance deltas are relative and stay right).
    n = common.track(font, TRACKING)
    changes.append({"change": "tracking", "units": TRACKING, "glyphs": n})

    # 6. Shared line box, names.
    common.set_line_metrics(font)
    changes.append({"change": "line metrics", "ascender": common.LINE_ASCENDER, "descender": common.LINE_DESCENDER, "lineGap": 0})
    original = font["name"].getDebugName(0)
    common.rename(font, FAMILY, style, original, DESCRIPTION)

    sizes = common.write(font, work, stem)
    shutil.copyfile(work / f"{stem}.woff2", out / f"{stem}.woff2")
    final = TTFont(work / f"{stem}.ttf")
    return {
        "source": source_name,
        "file": f"{stem}.woff2",
        "before": before,
        "after": common.report(final),
        "points": {"before": before_points, "after": point_counts(final)},
        "woff2_before": common.woff2_size_of_source_subset(source_name),
        "woff2_after": sizes["woff2"],
        "changes": changes,
    }


def point_counts(font: TTFont, chars: str = "aglrt") -> dict:
    cmap, glyf = font.getBestCmap(), font["glyf"]
    out = {}
    for c in chars:
        g = glyf[cmap[ord(c)]]
        out[c] = f"{cmap[ord(c)]}: " + ("composite" if g.isComposite() else str(len(g.coordinates)))
    return out


def soften_targets(font: TTFont) -> set[str]:
    """Letters and figures and their alternates, simple outlines only. Marks, punctuation and symbols keep their
    corners (small shapes whose corners are what make them read; the dots are round now anyway), and so do the
    SHARP glyphs. Composites (accented letters) follow their base glyphs."""
    cmap = font.getBestCmap()
    names = {name for code, name in cmap.items() if unicodedata.category(chr(code))[0] in "LN"}
    bases = {name.split(".", 1)[0] for name in names}
    hmtx, glyf = font["hmtx"], font["glyf"]
    out = set()
    for name in font.getGlyphOrder():
        if name.split(".", 1)[0] not in bases or name.split(".", 1)[0] in SHARP or hmtx[name][0] == 0:
            continue
        if any(part in name for part in (".numr", ".dnom", "superior", "inferior")):
            continue  # fraction and super/subscript figures: too small at text size for a round to show
        glyph = glyf[name]
        if glyph.isComposite() or glyph.numberOfContours <= 0:
            continue
        out.add(name)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = common.ROOT / "build" / "out" / "sans"
    faces = [build(name, style, stem, out, work) for name, style, stem in FACES]
    report = {
        "family": FAMILY,
        "numbers": {"x_height": X_HEIGHT, "tracking": TRACKING, "soften": SOFTEN, "default_features": DEFAULT_FEATURES, "sharp": sorted(SHARP)},
        "faces": faces,
    }
    path = common.ROOT / "build" / "out" / "sans.json"
    path.write_text(json.dumps(report, indent=1, default=str) + "\n")
    for face in faces:
        print(f"{face['file']}: {face['woff2_before']} -> {face['woff2_after']} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
