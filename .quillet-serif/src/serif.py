#!/usr/bin/env python3
"""Builds Quillet Serif, the reply face of the cmux agent chat, from Newsreader (SIL OFL 1.1, no Reserved
Font Name). It sets agent prose at 15 px with a 1.6 line height. What changes, and why: docs/design-serif.md.

    python3 build/serif.py --out fonts

Writes OUT/quillet-serif.woff2 and OUT/quillet-serif-italic.woff2 (variable wght, Latin) and
build/out/serif.json (before/after metrics and sizes, the change list, the checks).
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import common  # noqa: E402
from fontTools.pens.recordingPen import DecomposingRecordingPen  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402
from fontTools.varLib import instancer  # noqa: E402

FAMILY = "Quillet Serif"
COPYRIGHT = "Copyright 2020 The Newsreader Project Authors (https://github.com/productiontype/Newsreader)"
DESCRIPTION = (
    "Quillet Serif is a modified version of Newsreader: one optical size cut for 15 px screen prose, a taller "
    "x-height, a little more space, proportional figures and softened corners by default."
)

# --- The design (each number is argued in docs/design-serif.md). Units are 1000 per em: the build scales
# Newsreader's 2000-unit em to 1000 first, the em the shared line box and the other two faces use. --------
OPSZ = 12  # optical size pinned for 15 px screen text: sturdier hairlines and serifs, looser fit than opsz 15
UPM = 1000
X_HEIGHT = 500  # 0.50 em, from 469 (upright) and 479 (italic) at opsz 12
TRACK = {"upright": 6, "italic": 5}  # units added to every advance, half each side
# Corners: round the sharp convex straight-to-straight corners (serif tips, stem feet, square stroke ends)
# of letters; acute joins (more than 120 degrees of turn) stay sharp. Figures, punctuation and symbols are left.
SOFTEN = {"fraction": 0.3, "cap": 12.0, "min_turn": 60.0, "max_turn": 120.0, "min_edge": 12.0}
# Newsreader's only figure alternates are pnum (proportional lining, ".lf") and tnum; it has no old-style
# figures and no letter alternates (no ssNN, cvNN or salt). Prose gets the proportional figures; tnum keeps
# the tabular ones reachable (common.make_default carries tnum over to the new default glyphs).
DEFAULT_FEATURES: dict[str, list[str]] = {"upright": ["pnum"], "italic": ["pnum"]}
FIGURES = {"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"}

FACES = {
    "upright": {"source": "Newsreader[opsz,wght].ttf", "stem": "quillet-serif", "style": "Regular"},
    "italic": {"source": "Newsreader-Italic[opsz,wght].ttf", "stem": "quillet-serif-italic", "style": "Italic"},
}
POINT_GLYPHS = "aegry"


def points(font: TTFont, chars: str = POINT_GLYPHS) -> dict:
    cmap, glyf = font.getBestCmap(), font["glyf"]
    out = {}
    for c in chars:
        name = cmap[ord(c)]
        g = glyf[name]
        out[c] = {"glyph": name, "points": "composite" if g.isComposite() else len(g.coordinates), "contours": g.numberOfContours}
    return out


def figure_forms(font: TTFont) -> dict:
    """What each figure feature reaches from the default '1', to show pnum is the default and tnum still works."""
    one = font.getBestCmap()[ord("1")]
    out = {"default": one, "advance": font["hmtx"][one][0]}
    for tag in ("tnum", "pnum", "sups"):
        target = common.feature_mapping(font, [tag]).get(one)
        out[tag] = target and {"glyph": target, "advance": font["hmtx"][target][0]}
    return out


def softenable(font: TTFont) -> list[str]:
    """Letters (Unicode L*, by the cmap) with their alternates and ligatures. Not figures (old-style and
    tabular shapes are drawn crisp and their rhythm is the point), not punctuation or symbols (small marks,
    where a rounded corner reads as blur at 15 px)."""
    import unicodedata

    letters = {name for code, name in font.getBestCmap().items() if unicodedata.category(chr(code)).startswith("L")}
    keep = []
    for name in font.getGlyphOrder():
        stem = name.split(".", 1)[0]
        if name in letters or stem in letters or ("_" in stem and all(p in letters for p in stem.split("_"))):
            keep.append(name)
    return keep


def verify(woff2: Path, reference: dict) -> dict:
    """Reopens the woff2, instances it at the weight axis's min, default and max and draws every glyph."""
    font = TTFont(woff2)
    axis = next(a for a in font["fvar"].axes if a.axisTag == "wght")
    out = {"reopened": True, "glyphs": len(font.getGlyphOrder()), "axes": common.axis_order(font), "instances": {}}
    gs = None
    for wght in (axis.minValue, axis.defaultValue, axis.maxValue):
        inst = instancer.instantiateVariableFont(TTFont(woff2), {"wght": wght})
        gs = inst.getGlyphSet()
        errors = []
        for name in inst.getGlyphOrder():
            try:
                pen = DecomposingRecordingPen(gs)
                gs[name].draw(pen)
            except Exception as e:  # noqa: BLE001
                errors.append(f"{name}: {e}")
        x = common.measured(inst, "x")
        out["instances"][str(wght)] = {"glyph_errors": errors[:10], "n_errors": len(errors), "xHeight": x,
                                         "n_advance": inst["hmtx"][inst.getBestCmap()[ord("n")]][0]}
    out["ok"] = all(v["n_errors"] == 0 for v in out["instances"].values())
    return out


def metrics(font: TTFont) -> dict:
    out = common.report(font)
    out["sxHeight"], out["sCapHeight"] = font["OS/2"].sxHeight, font["OS/2"].sCapHeight
    em = out["upm"]
    out["em"] = {k: round(out[k] / em, 4) for k in ("xHeight", "capHeight", "ascender_b", "descender_p", "avgLowercaseAdvance")}
    out["px_at_15"] = {k: round(out[k] * 15 / em, 2) for k in ("xHeight", "capHeight", "avgLowercaseAdvance")}
    return out


def build_face(key: str, out: Path, work: Path) -> dict:
    from fontTools.ttLib.scaleUpem import scale_upem

    face = FACES[key]
    source = common.source(face["source"])
    original_points = points(source)
    font = instancer.instantiateVariableFont(source, {"opsz": OPSZ})
    pinned_2000 = metrics(font)
    changes = [f"opsz pinned at {OPSZ} (instancer); wght stays variable"]
    scale_upem(font, UPM)
    changes.append(f"em scaled {source['head'].unitsPerEm} -> {UPM} units (fontTools scale_upem: outlines, deltas, metrics, GPOS)")
    common.subset(font)  # first: every later pass then touches only the Latin glyphs and what GSUB reaches
    changes.append("Latin subset (the chat faces' Latin range), hinting dropped")
    before = metrics(font)
    before_points = points(font)
    before_figures = figure_forms(font)

    # Alternates first, while the cmap still names the plain forms and before outlines move.
    mapping = {a: b for a, b in common.feature_mapping(font, DEFAULT_FEATURES[key]).items() if a in FIGURES}
    alternates = {"features": DEFAULT_FEATURES[key], "characters": "".join(common.make_default(font, mapping)),
                  "map": mapping, "gsub_features": sorted({r.FeatureTag for r in font["GSUB"].table.FeatureList.FeatureRecord})}
    changes.append(f"default figures from {', '.join(DEFAULT_FEATURES[key])} (proportional lining): {alternates['characters']}; tnum reaches the tabular ones")

    font["OS/2"].sxHeight = common.measured(font, "x")  # the flat x-height of this optical size
    xh = common.set_x_height(font, X_HEIGHT)
    changes.append(f"x-height {xh['from']} -> {xh['to']} units (lowercase and its ligatures, accents over it, GPOS mark anchors); caps, ascenders, descenders kept")

    targets = softenable(font)
    corners = common.soften_corners(font, targets, **SOFTEN)
    changes.append(f"corners softened: {corners} corners in {len(targets)} letter glyphs, radius {SOFTEN['fraction']} of the shorter edge, at most {SOFTEN['cap']} units")

    tracked = common.track(font, TRACK[key])
    changes.append(f"tracking +{TRACK[key]} units on {tracked} spacing glyphs")

    common.set_line_metrics(font)
    font["OS/2"].sCapHeight = common.measured(font, "H")  # the source's field is opsz 18's; this is opsz 12's
    changes.append(f"line box {common.LINE_ASCENDER}/{common.LINE_DESCENDER}, gap 0, USE_TYPO_METRICS; OS/2 cap height {font['OS/2'].sCapHeight}")
    common.rename(font, FAMILY, face["style"], source["name"].getDebugName(0) or COPYRIGHT, DESCRIPTION)
    after = metrics(font)
    after_points = points(font)
    after_figures = figure_forms(font)
    sizes = common.write(font, work, face["stem"])
    woff2 = out / f"{face['stem']}.woff2"
    shutil.copyfile(work / f"{face['stem']}.woff2", woff2)  # only the woff2 goes to OUT (fonts/ holds no .ttf)
    before_size = common.woff2_size_of_source_subset(face["source"], pin={"opsz": OPSZ})
    full_size = common.woff2_size_of_source_subset(face["source"])
    return {
        "file": woff2.name,
        "source": face["source"],
        "woff2": {"before_same_subset_same_opsz": before_size, "before_same_subset_opsz_variable": full_size, "after": sizes["woff2"]},
        "metrics": {"pinned_source_2000upm": pinned_2000, "before": before, "after": after},
        "points": {"source_2000upm": original_points, "before": before_points, "after": after_points},
        "figures": {"before": before_figures, "after": after_figures},
        "alternates": alternates,
        "changes": changes,
        "verify": verify(woff2, after),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    work = common.ROOT / "build" / "out" / "serif"
    report = {"family": FAMILY, "opsz": OPSZ, "upm": UPM, "x_height": X_HEIGHT, "track": TRACK, "soften": SOFTEN, "faces": {}}
    for key in FACES:
        report["faces"][key] = build_face(key, args.out, work)
    path = common.ROOT / "build" / "out" / "serif.json"
    path.write_text(json.dumps(report, indent=1, default=str) + "\n")
    ok = all(f["verify"]["ok"] for f in report["faces"].values())
    for key, f in report["faces"].items():
        print(f"{f['file']}: {f['woff2']['after']} bytes (before {f['woff2']['before_same_subset_same_opsz']}), verify {'ok' if f['verify']['ok'] else 'FAILED'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
