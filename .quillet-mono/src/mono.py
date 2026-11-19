#!/usr/bin/env python3
"""Builds Quillet Mono, the code face of Quillet, from JetBrains Mono (SIL OFL 1.1, no Reserved Font Name).

It sets the code in agent replies: inline code and code blocks at the chat's default code scale, 0.875 of
15 px prose (13.1 px). What it changes, each with its reason in docs/design-mono.md:

- x-height (X_HEIGHT): the source's tall lowercase is brought down so that at 0.875 it sits just under
  Quillet Serif's (0.50 em at 15 px = 7.5 px), and the theme keeps the default code scale;
- default forms (DEFAULT_FEATURES): none swapped; the source's dotted zero stays, the slashed one behind `zero`;
- ligatures (DROP_FEATURES): the code ligatures are left out, so code reads as typed, and the file is smaller;
- terminals (SOFTEN): the sharp stroke ends and stem feet of letters and figures get a small round, sized so
  13 px stays crisp;
- the shared Quillet line box (common.set_line_metrics) and the name.

Every spacing glyph keeps one advance (600 units): the face stays monospaced.

    python3 build/mono.py --out fonts       writes fonts/quillet-mono.woff2, fonts/quillet-mono-italic.woff2
                                            and build/out/mono.json (the TTFs go to build/out/mono/)
"""

from __future__ import annotations

import argparse
import io
import json
import shutil
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import common  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402

FAMILY = "Quillet Mono"
DESCRIPTION = (
    "Quillet Mono is the code face of Quillet, cmux's type family for the agent chat: a modified version of "
    "JetBrains Mono under the SIL Open Font License 1.1, with a lower x-height for code set inside serif prose, "
    "a dotted zero and softened terminals."
)
FACES = [
    ("JetBrainsMono[wght].ttf", "Regular", "quillet-mono"),
    ("JetBrainsMono-Italic[wght].ttf", "Italic", "quillet-mono-italic"),
]

# Chat prose is 15 px; code is set at 0.875 of it. Quillet Serif's x-height is 0.50 em: 7.5 px.
PROSE_PX = 15.0
CODE_SCALE = 0.875
SERIF_X_HEIGHT = 0.50

# Units per em is 1000. 540 / 1000 * 13.125 px = 7.09 px, 0.41 px under the serif's 7.5 px (source: 550, 7.22 px).
X_HEIGHT = 540
# No tracking: 600 units is 7.9 px a character at 13.1 px, already open (see the notes).
TRACK = 0
# Features whose alternates become the default forms. Empty: the source has only `zero` (slashed), and the
# dotted default is the one we want (notes, section 3).
DEFAULT_FEATURES: list[str] = []
# Code ligatures out: chat code reads as typed. aalt (glyph-picker lists, unused on the web) goes too: it alone
# still reached the ligature glyphs once calt was gone.
DROP_FEATURES = ["calt", "aalt"]
# Round sharp convex corners: radius = fraction of the shorter edge at each master, at most cap units
# (1 px at 13.1 px is 76 units, so the cap is a quarter pixel: softer, never blurred). curve_ends: the cut
# terminals of curved strokes (a c f j r s t y) round too, not only stems and slabs.
SOFTEN = {"fraction": 0.2, "cap": 20, "curve_ends": True}


def code_px(units: float) -> float:
    return round(units / 1000 * PROSE_PX * CODE_SCALE, 2)


def soften_targets(font: TTFont) -> set[str]:
    """Letters and figures (and their alternates). Punctuation, operators and brackets keep their sharp,
    geometric ends: they are the code's structure, and the zero-width marks have no stroke ends to speak of."""
    cmap = font.getBestCmap()
    base = {name for code, name in cmap.items() if unicodedata.category(chr(code))[0] in "LN"}
    order = font.getGlyphOrder()
    return {name for name in order if name in base or name.split(".", 1)[0] in base}


def point_counts(font: TTFont, chars: str = "0aglr") -> dict:
    glyf, cmap = font["glyf"], font.getBestCmap()
    out = {}
    for c in chars:
        name = cmap[ord(c)]
        glyph = glyf[name]
        if glyph.isComposite():
            out[c] = {"glyph": name, "composite": [comp.glyphName for comp in glyph.components]}
        else:
            out[c] = {"glyph": name, "points": len(glyph.coordinates), "contours": glyph.numberOfContours}
    return out


def overlap_flagged(font: TTFont) -> dict:
    """Simple glyphs carrying OVERLAP_SIMPLE (0x40 on the first point), which rasterizers need for overlaps."""
    glyf = font["glyf"]
    simple = [n for n in font.getGlyphOrder() if glyf[n].numberOfContours > 0]
    return {"simple": len(simple), "flagged": sum(1 for n in simple if glyf[n].flags[0] & 0x40)}


def advances(font: TTFont) -> list[int]:
    return sorted({a for a, _ in font["hmtx"].metrics.values() if a})


def verify(path: Path) -> dict:
    """Reopens the woff2, instances it at the weight axis' min, default and max, and checks that every glyph
    compiles there and every spacing glyph has one advance."""
    from fontTools.varLib import instancer

    font = TTFont(path)
    axis = next(a for a in font["fvar"].axes if a.axisTag == "wght")
    names = {i: font["name"].getDebugName(i) for i in (0, 1, 2, 4, 6, 16)}
    result = {"reopened": True, "glyphs": len(font.getGlyphOrder()), "advances": advances(font), "names": names,
              "features": sorted({r.FeatureTag for r in font["GSUB"].table.FeatureList.FeatureRecord}),
              "instances": {}}
    for value in (axis.minValue, axis.defaultValue, axis.maxValue):
        static = instancer.instantiateVariableFont(TTFont(path), {"wght": value})
        glyf = static["glyf"]
        errors = []
        for name in static.getGlyphOrder():
            try:
                glyf[name].compile(glyf)
                glyf[name].recalcBounds(glyf)
            except Exception as error:  # noqa: BLE001: every glyph is checked, every failure listed
                errors.append(f"{name}: {error}")
        buffer = io.BytesIO()
        static.save(buffer)
        result["instances"][str(value)] = {
            "glyph_errors": errors,
            "advances": advances(static),
            "xHeight": common.measured(static, "x"),
            "bytes_ttf": len(buffer.getvalue()),
        }
    adv_sets = [result["advances"], *(i["advances"] for i in result["instances"].values())]
    result["monospace"] = all(len(a) == 1 for a in adv_sets) and len({a[0] for a in adv_sets}) == 1
    result["named"] = names[1] == FAMILY and "JetBrains Mono Project Authors" in (names[0] or "")
    result["ok"] = (result["monospace"] and result["named"] and not set(DROP_FEATURES) & set(result["features"])
                    and not any(i["glyph_errors"] for i in result["instances"].values()))
    return result


def build_face(source_name: str, style: str, stem: str, out: Path) -> dict:
    font = common.source(source_name)
    original_copyright = font["name"].getDebugName(0)
    before = common.report(font)
    before["points"] = point_counts(font)
    before["advances"] = advances(font)
    before["overlap_flagged_glyphs"] = overlap_flagged(font)
    before["xHeight_px_at_code_scale"] = code_px(before["xHeight"])
    changes: list[str] = []

    for tag in DEFAULT_FEATURES:
        mapping = common.feature_mapping(font, [tag])
        if not mapping:
            raise SystemExit(f"{source_name}: {tag} has no single substitutions")
        changed = common.make_default(font, mapping)
        changes.append(f"default forms from {tag}: {''.join(changed)} ({', '.join(f'{a}>{b}' for a, b in sorted(mapping.items()))})")

    common.subset(font, drop_features=DROP_FEATURES)
    changes.append(f"Latin subset; features dropped: {', '.join(DROP_FEATURES)}")

    xh = common.set_x_height(font, X_HEIGHT)
    changes.append(f"x-height {xh['from']} -> {xh['to']} ({code_px(xh['from'])} -> {code_px(xh['to'])} px at 13.1 px)")

    corners = common.soften_corners(font, soften_targets(font), **SOFTEN)
    changes.append(f"softened {corners} corners on letters and figures (fraction {SOFTEN['fraction']}, cap {SOFTEN['cap']})")

    if TRACK:
        common.track(font, TRACK)
        changes.append(f"tracking +{TRACK} units")

    common.set_line_metrics(font)
    changes.append(f"line box {common.LINE_ASCENDER}/{common.LINE_DESCENDER}, no gap")
    common.rename(font, FAMILY, style, original_copyright, DESCRIPTION)
    work = common.ROOT / "build" / "out" / "mono"  # the TTF stays here; only the woff2 goes to --out (fonts/)
    sizes = common.write(font, work, stem)
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(work / f"{stem}.woff2", out / f"{stem}.woff2")

    after = common.report(font)
    after["points"] = point_counts(font)
    after["advances"] = advances(font)
    after["overlap_flagged_glyphs"] = overlap_flagged(font)
    after["xHeight_px_at_code_scale"] = code_px(after["xHeight"])
    before_size = common.woff2_size_of_source_subset(source_name)
    before_size_no_calt = _source_subset_size(source_name, DROP_FEATURES)
    return {
        "source": source_name,
        "file": f"{stem}.woff2",
        "before": before,
        "after": after,
        "bytes": {
            "source_latin_woff2": before_size,
            "source_latin_woff2_without_dropped_features": before_size_no_calt,
            "woff2": sizes["woff2"],
            "ttf": sizes["ttf"],
        },
        "changes": changes,
        "verify": verify(out / f"{stem}.woff2"),
    }


def _source_subset_size(name: str, drop: list[str]) -> int:
    font = common.source(name)
    common.subset(font, drop_features=drop)
    font.flavor = "woff2"
    buffer = io.BytesIO()
    font.save(buffer)
    return len(buffer.getvalue())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    report = {
        "family": FAMILY,
        "target": {
            "prose_px": PROSE_PX,
            "code_scale": CODE_SCALE,
            "code_px": PROSE_PX * CODE_SCALE,
            "serif_x_height_px": PROSE_PX * SERIF_X_HEIGHT,
            "mono_x_height_px": code_px(X_HEIGHT),
        },
        "settings": {
            "x_height": X_HEIGHT,
            "track": TRACK,
            "default_features": DEFAULT_FEATURES,
            "drop_features": DROP_FEATURES,
            "soften": SOFTEN,
        },
        "faces": [],
    }
    for source_name, style, stem in FACES:
        print(f"building {stem} from {source_name}", flush=True)
        report["faces"].append(build_face(source_name, style, stem, args.out))
    out = common.ROOT / "build" / "out"
    out.mkdir(parents=True, exist_ok=True)
    (out / "mono.json").write_text(json.dumps(report, indent=1) + "\n")
    for face in report["faces"]:
        b = face["bytes"]
        print(f"{face['file']}: {b['woff2']} bytes (source Latin {b['source_latin_woff2']}), verify ok={face['verify']['ok']}")
    return 0 if all(face["verify"]["ok"] for face in report["faces"]) else 1


if __name__ == "__main__":
    sys.exit(main())
