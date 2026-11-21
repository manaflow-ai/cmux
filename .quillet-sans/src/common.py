"""Shared pieces of the Quillet build: sources, the edit-every-master primitive, metrics, subsetting, naming.

Every outline edit goes through `edit_glyph`: it computes the glyph's points at the default and at every master
of the variable font, lets a function map those point lists (it may add points, the same way in every master),
then solves the gvar deltas again with fontTools' VariationModel, so the variable font interpolates as before.
This is the method of cmux Sans (manaflow-ai/cmux scripts/fonts/cmux-sans/build.py), generalized to edits that
change a glyph's point structure.

Needs fontTools and brotli (`pip install -r build/requirements.txt`).
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import unicodedata
from pathlib import Path
from typing import Callable, Iterable

from fontTools.misc.fixedTools import otRound
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables.TupleVariation import TupleVariation
from fontTools.ttLib.tables._g_l_y_f import GlyphCoordinates, flagOnCurve, flagOverlapSimple
from fontTools.varLib.models import VariationModel, supportScalar

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "sources"

# Fontsource's "latin" subset, the range every bundled cmux chat face is cut to.
LATIN = [
    *range(0x20, 0x7F), *range(0xA0, 0x100), 0x131, 0x152, 0x153, 0x2BB, 0x2BC, 0x2C6, 0x2DA, 0x2DC, 0x304,
    0x308, 0x329, *range(0x2000, 0x2070), 0x20AC, 0x2122, 0x2191, 0x2193, 0x2212, 0x2215, 0xFEFF, 0xFFFD,
]

# One line box for all three faces, so a line that mixes them (inline code in a reply) keeps its baseline and
# height. In 1000-unit ems (Newsreader is 2000 upm; set_line_metrics scales). 960 + 240 = 1.2 em, the content area browsers centre text in.
LINE_ASCENDER = 960
LINE_DESCENDER = -240

MANAFLOW = "Modifications copyright 2026 Manaflow, Inc. (Quillet)."
VENDOR = "QLLT"


def source(name: str) -> TTFont:
    """A font from sources/, checked against sources/SOURCES.json."""
    path = SOURCES / name
    pinned = json.loads((SOURCES / "SOURCES.json").read_text())
    want = pinned["files"][name]["sha256"]
    if not path.exists():  # a checkout without the binaries: fetch the pinned upstream file
        import urllib.parse
        import urllib.request

        url = f"https://raw.githubusercontent.com/google/fonts/{pinned['commit']}/ofl/{pinned['files'][name]['dir']}/{urllib.parse.quote(name)}"
        with urllib.request.urlopen(url) as response:
            path.write_bytes(response.read())
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != want:
        raise SystemExit(f"{path}: sha256 does not match {want}")
    return TTFont(path, recalcTimestamp=False)  # reproducible files


def axis_order(font: TTFont) -> list[str]:
    return [axis.axisTag for axis in font["fvar"].axes] if "fvar" in font else []


# --- Editing outlines at every master --------------------------------------------------------------------

Points = list[tuple[float, float]]
# (masters, end_pts, flags) -> (masters, end_pts, flags). masters[0] is the default. Phantom points are not
# passed; they are kept as they were.
GlyphEdit = Callable[[list[Points], list[int], list[int]], tuple[list[Points], list[int], list[int]]]


def _masters(font: TTFont, name: str):
    glyf, gvar = font["glyf"], font.get("gvar")
    coords, controls = glyf._getCoordinatesAndControls(name, font["hmtx"].metrics, font["vmtx"].metrics if "vmtx" in font else None)
    end_pts = list(controls[1])
    variations = list(gvar.variations.get(name, [])) if gvar else []
    for variation in variations:
        if None in variation.coordinates:
            variation.calcInferredDeltas(coords, end_pts)
    locations: list[dict] = [{}]
    for variation in variations:
        peak = {tag: values[1] for tag, values in variation.axes.items() if values[1] != 0}
        if peak not in locations:
            locations.append(peak)

    def at(location) -> GlyphCoordinates:
        points = GlyphCoordinates(coords)
        for variation in variations:
            scalar = supportScalar(location, variation.axes)
            if scalar:
                points += GlyphCoordinates(variation.coordinates) * scalar
        return points

    return coords, end_pts, locations, [at(location) for location in locations]


def edit_glyph(font: TTFont, name: str, edit: GlyphEdit) -> bool:
    """Applies `edit` to a simple glyph at every master and solves its deltas again. False for composites/empty."""
    glyf = font["glyf"]
    glyph = glyf[name]
    if glyph.isComposite() or glyph.numberOfContours <= 0:
        return False
    coords, end_pts, locations, masters = _masters(font, name)
    n_real = len(coords) - 4
    phantoms = [list(m)[n_real:] for m in masters]
    flags = list(glyph.flags)
    new_masters, new_end_pts, new_flags = edit([list(m)[:n_real] for m in masters], end_pts, flags)
    if len({len(m) for m in new_masters}) != 1 or len(new_masters[0]) != len(new_flags):
        raise SystemExit(f"{name}: the edit changed masters unevenly")
    if flags and flags[0] & flagOverlapSimple and new_flags:  # keep OVERLAP_SIMPLE: edits rebuild flags from on-curve only
        new_flags = [new_flags[0] | flagOverlapSimple, *new_flags[1:]]
    full = [GlyphCoordinates(list(m) + p) for m, p in zip(new_masters, phantoms)]
    default = full[0]
    glyph.coordinates = GlyphCoordinates([(otRound(x), otRound(y)) for x, y in list(default)[: len(new_flags)]])
    glyph.endPtsOfContours = list(new_end_pts)
    glyph.flags = bytearray(new_flags)
    from fontTools.ttLib.tables import ttProgram

    glyph.program = ttProgram.Program()  # point indices changed: the hints go (the subset drops them anyway)
    glyph.program.fromBytecode(b"")
    if len(locations) > 1:
        model = VariationModel(locations, axisOrder=axis_order(font))
        deltas = model.getDeltas(full)
        rounded = GlyphCoordinates([(otRound(x), otRound(y)) for x, y in default])
        new = []
        for support, delta in zip(model.supports[1:], deltas[1:]):
            variation = TupleVariation(support, [(otRound(x), otRound(y)) for x, y in delta])
            variation.optimize(rounded, new_end_pts, tolerance=0.5)
            new.append(variation)
        font["gvar"].variations[name] = new
    glyph.recalcBounds(glyf)
    return True


def map_points(f: Callable[[float, float], tuple[float, float]]) -> GlyphEdit:
    """An edit that moves every point with f(x, y) and keeps the structure."""

    def edit(masters, end_pts, flags):
        return [[f(x, y) for x, y in m] for m in masters], end_pts, flags

    return edit


# --- Height: stretch lowercase to a new x-height -------------------------------------------------------

NOT_ON_X_HEIGHT = (".sc", ".sups", ".subs", ".sinf", ".numr", ".dnom", "superior", "inferior", ".case")


def lowercase_glyphs(font: TTFont) -> set[str]:
    """Lowercase letters (Unicode Ll) and their alternates, except small caps and figure-height forms."""
    # Base names, so plain forms count even after make_default points the cmap at "l.ss02" (fix from the sans build).
    base = {name.split(".", 1)[0] for code, name in font.getBestCmap().items() if unicodedata.category(chr(code)) == "Ll"}
    found = set()
    for name in font.getGlyphOrder():
        if any(part in name for part in NOT_ON_X_HEIGHT):
            continue
        stem = name.split(".", 1)[0]
        # Ligatures (f_i, f_f_l: reached by liga, not the cmap) sit on the x-height too.
        if name in base or stem in base or ("_" in stem and all(part in base for part in stem.split("_"))):
            found.add(name)
    if "GSUB" in font:  # ligatures named otherwise ("fi", "fl"): a GSUB ligature of lowercase is lowercase
        for lookup in font["GSUB"].table.LookupList.Lookup:
            for table in lookup.SubTable:
                table = table.ExtSubTable if lookup.LookupType == 7 else table
                for first, ligatures in (getattr(table, "ligatures", None) or {}).items():
                    for lig in ligatures:
                        if first in found and all(c in found for c in lig.Component):
                            found.add(lig.LigGlyph)
    return found


def measured(font: TTFont, char: str, edge: str = "yMax") -> int:
    glyf = font["glyf"]
    glyph = glyf[font.getBestCmap()[ord(char)]]
    glyph.recalcBounds(glyf)
    return getattr(glyph, edge)


def set_x_height(font: TTFont, target: float, glyphs: Iterable[str] | None = None) -> dict:
    """Stretches lowercase between the baseline and the x-height to `target`, and from there to the ascender, so
    ascenders, descenders and capitals keep their heights. Composite marks over lowercase and the GPOS mark
    anchors move up with the letters. Returns {"from": old, "to": target}."""
    glyf = font["glyf"]
    x_height = font["OS/2"].sxHeight or measured(font, "x")
    if otRound(target) == x_height:
        return {"from": x_height, "to": x_height}
    ascender = max(measured(font, c) for c in "bdhkl")

    def f(y: float) -> float:
        if 0 < y <= x_height:
            return y * target / x_height
        if x_height < y < ascender:
            return target + (y - x_height) * (ascender - target) / (ascender - x_height)
        return y

    lowercase = set(glyphs) if glyphs is not None else lowercase_glyphs(font)
    slope = math.tan(math.radians(-font["post"].italicAngle))  # italics: a point moved in y moves along the slant
    for name in sorted(lowercase):
        edit_glyph(font, name, map_points(lambda x, y: (x + (f(y) - y) * slope, f(y))))
    shift = otRound(target - x_height)
    for name in glyf.keys():
        glyph = glyf[name]
        if not glyph.isComposite() or glyph.components[0].glyphName not in lowercase:
            continue
        for component in glyph.components[1:]:
            mark = glyf[component.glyphName]
            mark.recalcBounds(glyf)
            if mark.numberOfContours and mark.yMin + component.y > x_height * 0.6:
                component.y += shift
        glyph.recalcBounds(glyf)
    for table in _gpos_subtables(font, 4):
        for base, record in zip(table.BaseCoverage.glyphs, table.BaseArray.BaseRecord):
            if base in lowercase:
                for anchor in record.BaseAnchor:
                    if anchor is not None and anchor.YCoordinate > x_height * 0.6:
                        anchor.YCoordinate += shift
    font["OS/2"].sxHeight = otRound(target)
    return {"from": x_height, "to": otRound(target)}


def _gpos_subtables(font: TTFont, lookup_type: int):
    if "GPOS" not in font:
        return
    for lookup in font["GPOS"].table.LookupList.Lookup:
        for table in lookup.SubTable:
            if lookup.LookupType == 9:
                table = table.ExtSubTable
            if getattr(table, "LookupType", lookup.LookupType) == lookup_type:
                yield table


# --- Terminals: round sharp convex corners ---------------------------------------------------------------


def soften_corners(
    font: TTFont,
    glyphs: Iterable[str],
    fraction: float,
    cap: float,
    min_turn: float = 55.0,
    max_turn: float = 125.0,
    min_edge: float = 20.0,
    curve_ends: bool = False,
) -> int:
    """Rounds the sharp convex corners where two straight segments meet (stroke ends, stem feet): the corner
    point becomes an off-curve control between two new on-curve points, one along each edge. With
    `curve_ends`, a corner where a straight cut meets a curve (the terminals of a, c, f, j, r, s, t) rounds
    too: the edge on the curve side is the tangent toward its off-curve point, so the new point lies on it. The radius at each
    master is `fraction` of the shorter edge there, at most `cap` units, so thin weights round less than bold.
    Which corners round is decided on the default master and applied to the same points in every master, so the
    masters stay compatible. TrueType draws ink on the right of a contour, so a right turn (negative cross
    product) is convex in every contour, outer or counter. Returns the number of corners rounded."""
    total = 0

    def edit(masters, end_pts, flags):
        nonlocal total
        default = masters[0]
        start = 0
        chosen: list[int] = []
        for end in end_pts:
            idx = list(range(start, end + 1))
            n = len(idx)
            for k, i in enumerate(idx):
                prev, nxt = idx[k - 1], idx[(k + 1) % n]
                if not flags[i] & flagOnCurve:
                    continue
                if not curve_ends and not (flags[prev] & flagOnCurve and flags[nxt] & flagOnCurve):
                    continue
                (px, py), (x, y), (nx, ny) = default[prev], default[i], default[nxt]
                ax, ay, bx, by = x - px, y - py, nx - x, ny - y
                la, lb = math.hypot(ax, ay), math.hypot(bx, by)
                if la < min_edge or lb < min_edge:
                    continue
                cross = ax * by - ay * bx
                turn = math.degrees(math.acos(max(-1.0, min(1.0, (ax * bx + ay * by) / (la * lb)))))
                if cross < 0 and min_turn <= turn <= max_turn:
                    chosen.append(i)
            start = end + 1
        if not chosen:
            return masters, end_pts, flags
        total += len(chosen)
        chosen_set = set(chosen)
        new_masters = []
        for m in masters:
            out: Points = []
            start = 0
            for end in end_pts:
                idx = list(range(start, end + 1))
                n = len(idx)
                for k, i in enumerate(idx):
                    if i not in chosen_set:
                        out.append(m[i])
                        continue
                    prev, nxt = idx[k - 1], idx[(k + 1) % n]
                    (px, py), (x, y), (nx, ny) = m[prev], m[i], m[nxt]
                    la, lb = math.hypot(x - px, y - py), math.hypot(nx - x, ny - y)
                    r = min(cap, fraction * min(la, lb), 0.45 * la, 0.45 * lb)
                    ua = ((x - px) / la, (y - py) / la) if la else (0.0, 0.0)
                    ub = ((nx - x) / lb, (ny - y) / lb) if lb else (0.0, 0.0)
                    out.extend([(x - ua[0] * r, y - ua[1] * r), (x, y), (x + ub[0] * r, y + ub[1] * r)])
                start = end + 1
            new_masters.append(out)
        new_flags: list[int] = []
        new_end_pts: list[int] = []
        start = 0
        for end in end_pts:
            for i in range(start, end + 1):
                if i in chosen_set:
                    new_flags.extend([flagOnCurve, 0, flagOnCurve])
                else:
                    new_flags.append(flags[i] & flagOnCurve)
            new_end_pts.append(len(new_flags) - 1)
            start = end + 1
        return new_masters, new_end_pts, new_flags

    for name in sorted(set(glyphs)):
        edit_glyph(font, name, edit)
    return total


# --- Spacing -------------------------------------------------------------------------------------------


def track(font: TTFont, units: int, skip: Callable[[str], bool] = lambda name: False) -> int:
    """Adds `units` to every spacing glyph's advance, half on each side: the outline (and its composites' and
    GPOS anchors' x) moves right by units / 2. Zero-width glyphs (marks) are left alone. The variable advances
    (HVAR, gvar phantoms) are deltas and keep working. Returns the number of glyphs changed."""
    if units == 0:
        return 0
    half = units // 2
    glyf, hmtx = font["glyf"], font["hmtx"]
    changed = set()
    for name in font.getGlyphOrder():
        advance, lsb = hmtx[name]
        if advance == 0 or skip(name):
            continue
        hmtx[name] = (advance + units, lsb + half)
        changed.add(name)
    # Simple glyphs: move the default outline; deltas are relative, so every master moves with it.
    for name in changed:
        glyph = glyf[name]
        if glyph.isComposite():
            continue
        if glyph.numberOfContours > 0:
            glyph.coordinates = GlyphCoordinates([(x + half, y) for x, y in glyph.coordinates])
            glyph.recalcBounds(glyf)
    # Composites: a component that is itself a changed spacing glyph already moved by half; other components
    # (marks, zero width) move by half here so they stay over their base.
    for name in changed:
        glyph = glyf[name]
        if not glyph.isComposite():
            continue
        for component in glyph.components:
            if component.glyphName not in changed:
                component.x += half
        glyph.recalcBounds(glyf)
    for table in _gpos_subtables(font, 4):  # mark-to-base: base anchors move with the base
        for base, record in zip(table.BaseCoverage.glyphs, table.BaseArray.BaseRecord):
            if base in changed:
                for anchor in record.BaseAnchor:
                    if anchor is not None:
                        anchor.XCoordinate += half
    for table in _gpos_subtables(font, 5):  # mark-to-ligature
        for lig, attach in zip(table.LigatureCoverage.glyphs, table.LigatureArray.LigatureAttach):
            if lig in changed:
                for component in attach.ComponentRecord:
                    for anchor in component.LigatureAnchor:
                        if anchor is not None:
                            anchor.XCoordinate += half
    font["hhea"].advanceWidthMax = max(a for a, _ in hmtx.metrics.values())
    return len(changed)


# --- Alternates as defaults ------------------------------------------------------------------------------


def feature_mapping(font: TTFont, tags: Iterable[str]) -> dict[str, str]:
    """The single substitutions of these GSUB features (ssNN, cvNN, zero, ...)."""
    tags = set(tags)
    gsub = font["GSUB"].table
    mapping: dict[str, str] = {}
    for record in gsub.FeatureList.FeatureRecord:
        if record.FeatureTag not in tags:
            continue
        for index in record.Feature.LookupListIndex:
            lookup = gsub.LookupList.Lookup[index]
            for table in lookup.SubTable:
                table = table.ExtSubTable if lookup.LookupType == 7 else table
                mapping.update(getattr(table, "mapping", {}) or {})
                for name, alternates in (getattr(table, "alternates", {}) or {}).items():
                    mapping.setdefault(name, alternates[0])
    return mapping


def make_default(font: TTFont, mapping: dict[str, str]) -> list[str]:
    """Points the cmap at the alternate forms, so the face draws them without a feature (native text too).
    The plain forms stay in the font and the same feature reaches them (_follow_default_forms). Returns the
    characters changed."""
    changed = []
    moved: dict[str, str] = {}
    for table in font["cmap"].tables:
        for code, name in list(table.cmap.items()):
            if name in mapping:
                table.cmap[code] = mapping[name]
                changed.append(chr(code))
                moved[name] = mapping[name]
    _follow_default_forms(font, moved)
    return sorted(set(changed))


def _follow_default_forms(font: TTFont, moved: dict[str, str]) -> None:
    """Fix: a re-pointed cmap alone left the plain form unreachable (the feature mapped plain -> alt, and the text
    now holds alt), other features (smcp, tnum, lnum, ...) no longer applied to the new default, and composites
    (accented letters) still drew the plain form. So: a stylistic feature (ssNN, cvNN, salt) whose lookup maps
    plain -> alt also maps alt -> plain (the set now flips back to the plain form); a paired feature (pnum, onum,
    zero, ...) keeps its meaning, the alternate being what it asks for; every other single substitution of plain
    also applies to alt; composites built on plain use alt when the two have the same advance."""
    if not moved or "GSUB" not in font:
        return
    gsub = font["GSUB"].table
    stylistic = re.compile(r"ss\d\d|cv\d\d|salt")
    direct = {i for record in gsub.FeatureList.FeatureRecord if stylistic.fullmatch(record.FeatureTag)
              for i in record.Feature.LookupListIndex}
    for index, lookup in enumerate(gsub.LookupList.Lookup):
        for table in lookup.SubTable:
            table = table.ExtSubTable if lookup.LookupType == 7 else table
            mapping = getattr(table, "mapping", None)
            if getattr(table, "LookupType", lookup.LookupType) != 1 or mapping is None:
                continue
            for plain, alt in moved.items():
                if plain not in mapping or alt in mapping:
                    continue
                if mapping[plain] == alt:
                    if index in direct:
                        mapping[alt] = plain
                else:
                    mapping[alt] = mapping[plain]
    glyf, hmtx = font["glyf"], font["hmtx"]
    for name in glyf.keys():
        glyph = glyf[name]
        if name in moved.values() or not glyph.isComposite():
            continue
        for component in glyph.components:
            alt = moved.get(component.glyphName)
            if alt and hmtx[alt][0] == hmtx[component.glyphName][0]:
                component.glyphName = alt


def features(font: TTFont) -> dict[str, list[str]]:
    """GSUB feature tags -> example substitutions, for the notes."""
    out: dict[str, list[str]] = {}
    gsub = font["GSUB"].table if "GSUB" in font else None
    if gsub is None:
        return out
    for record in gsub.FeatureList.FeatureRecord:
        mapping = feature_mapping(font, [record.FeatureTag])
        out.setdefault(record.FeatureTag, sorted(f"{a}>{b}" for a, b in mapping.items())[:12])
    return out


# --- Vertical metrics, subsetting, naming, output -----------------------------------------------------


def set_line_metrics(font: TTFont) -> None:
    """The shared line box (LINE_ASCENDER, LINE_DESCENDER, no gap) in hhea and OS/2 typo, with USE_TYPO_METRICS;
    win metrics cover the subset's ink so nothing clips on Windows."""
    glyf = font["glyf"]
    y_max = max((glyf[n].yMax for n in glyf.keys() if getattr(glyf[n], "numberOfContours", 0)), default=0)
    y_min = min((glyf[n].yMin for n in glyf.keys() if getattr(glyf[n], "numberOfContours", 0)), default=0)
    hhea, os2 = font["hhea"], font["OS/2"]
    # fix: the box is in 1000-unit ems; Newsreader is 2000 upm, so scale (1.0 for the 1000-upm sources)
    scale = font["head"].unitsPerEm / 1000
    ascender, descender = otRound(LINE_ASCENDER * scale), otRound(LINE_DESCENDER * scale)
    hhea.ascent, hhea.descent, hhea.lineGap = ascender, descender, 0
    os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap = ascender, descender, 0
    os2.usWinAscent = max(ascender, y_max)
    os2.usWinDescent = max(-descender, -y_min)
    os2.fsSelection |= 1 << 7
    if "MVAR" in font:
        del font["MVAR"]  # metrics no longer vary with weight


def subset(font: TTFont, unicodes: Iterable[int] = LATIN, drop_features: Iterable[str] = ()) -> None:
    from fontTools import subset as fsubset

    options = fsubset.Options()
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.hinting = False
    options.layout_features = ["*"]
    options.drop_tables += ["DSIG"]
    drop = set(drop_features)
    if drop:
        keep = {record.FeatureTag for record in font["GSUB"].table.FeatureList.FeatureRecord} if "GSUB" in font else set()
        if "GPOS" in font:
            keep |= {record.FeatureTag for record in font["GPOS"].table.FeatureList.FeatureRecord}
        options.layout_features = sorted(keep - drop)
    if "gvar" in font:  # fix: after varLib.instancer the lazy gvar lacks glyphs with no deltas left; subset KeyErrors
        gvar = font["gvar"]
        gvar.variations = {g: gvar.variations[g] if g in gvar.variations else [] for g in font.getGlyphOrder()}
    subsetter = fsubset.Subsetter(options)
    subsetter.populate(unicodes=list(unicodes))
    subsetter.subset(font)


def rename(font: TTFont, family: str, style: str, original_copyright: str, description: str) -> None:
    """Names the face (family, style), keeps the original copyright line and adds ours, drops the upstream
    vendor and designer credits from the name fields that would say this build is theirs (the OFL keeps their
    copyright, which stays in name 0 and the license)."""
    names = font["name"]
    ps_family = family.replace(" ", "")
    italic = "Italic" in style
    full = f"{family} {style}" if style != "Regular" else family
    for record in list(names.names):
        if record.nameID >= 256:
            continue  # axis and instance names: keep
        names.removeNames(nameID=record.nameID)
    for args in [
        (f"{original_copyright} {MANAFLOW}", 0),
        (family, 1),
        ("Italic" if italic else "Regular", 2),
        (f"2.000;{VENDOR};{ps_family}-{style.replace(' ', '')}", 3),
        (full, 4),
        ("Version 2.000", 5),
        (f"{ps_family}-{style.replace(' ', '')}", 6),
        ("Manaflow, Inc.", 8),
        (description, 10),
        ("https://github.com/manaflow-ai/cmux-quillet-look", 11),
        ("This Font Software is licensed under the SIL Open Font License, Version 1.1.", 13),
        ("https://openfontlicense.org", 14),
        (family, 16),
        (style, 17),
        (ps_family, 25),
    ]:
        names.setName(args[0], args[1], 3, 1, 0x409)
    font["OS/2"].achVendID = VENDOR
    if "fvar" in font:
        for instance in font["fvar"].instances:
            if instance.postscriptNameID != 0xFFFF:
                sub = names.getDebugName(instance.subfamilyNameID) or "Instance"
                names.setName(f"{ps_family}-{sub.replace(' ', '')}", instance.postscriptNameID, 3, 1, 0x409)
    if "DSIG" in font:
        del font["DSIG"]


def sync_side_bearings(font: TTFont) -> None:
    """hmtx lsb = glyph xMin, which outline edits (soften_corners) change: renderers place the outline by
    xMin - lsb, so a stale lsb shifts the glyph."""
    glyf, hmtx = font["glyf"], font["hmtx"]
    for name in font.getGlyphOrder():
        glyph = glyf[name]
        if glyph.isComposite() or glyph.numberOfContours > 0:
            glyph.recalcBounds(glyf)
            hmtx[name] = (hmtx[name][0], glyph.xMin)


def write(font: TTFont, out: Path, stem: str) -> dict[str, int]:
    """Writes STEM.ttf and STEM.woff2; returns their sizes."""
    out.mkdir(parents=True, exist_ok=True)
    sync_side_bearings(font)
    font.flavor = None
    ttf = out / f"{stem}.ttf"
    font.save(ttf)
    font.flavor = "woff2"
    woff2 = out / f"{stem}.woff2"
    font.save(woff2)
    font.flavor = None
    return {"ttf": ttf.stat().st_size, "woff2": woff2.stat().st_size}


def woff2_size_of_source_subset(name: str, unicodes: Iterable[int] = LATIN, pin: dict | None = None) -> int:
    """The 'before' size: the untouched source, cut to the same subset (and the same pinned axes), as woff2."""
    import io

    font = source(name)
    if pin:
        from fontTools.varLib import instancer

        font = instancer.instantiateVariableFont(font, pin)
    subset(font, unicodes)
    font.flavor = "woff2"
    buffer = io.BytesIO()
    font.save(buffer)
    return len(buffer.getvalue())


def report(font: TTFont) -> dict:
    """The metrics the notes quote."""
    os2 = font["OS/2"]
    cmap = font.getBestCmap()
    hmtx = font["hmtx"]
    lower = [c for c in "abcdefghijklmnopqrstuvwxyz" if ord(c) in cmap]
    return {
        "upm": font["head"].unitsPerEm,
        "xHeight": measured(font, "x"),
        "capHeight": measured(font, "H"),
        "ascender_b": measured(font, "b"),
        "descender_p": measured(font, "p", "yMin"),
        "avgLowercaseAdvance": round(sum(hmtx[cmap[ord(c)]][0] for c in lower) / len(lower), 1),
        "hhea": [font["hhea"].ascent, font["hhea"].descent, font["hhea"].lineGap],
        "win": [os2.usWinAscent, os2.usWinDescent],
        "glyphs": len(font.getGlyphOrder()),
        "axes": {a.axisTag: [a.minValue, a.defaultValue, a.maxValue] for a in font["fvar"].axes} if "fvar" in font else {},
    }
