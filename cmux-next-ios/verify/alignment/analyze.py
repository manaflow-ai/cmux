"""Leading-edge analysis of one simulator screen: AX tree + screenshot -> measurements.

Used by measure.py. Everything in points (screenshot px / scale), top-left origin.

- headers:    AX headings (section headers) with the x where their text's ink starts
              (Vision OCR line inside the heading frame, ink found by pixel scan).
- rows:       AX rows (buttons, toggles, cells, menu items, at least 180 pt wide). Title: the
              row's first non-icon child text (AX StaticText), else the topmost OCR line in the
              row. title_ax_x is the AX frame; title_ink_x where the title's ink starts (a pixel
              cluster scan that excludes the gutter mark, so it works for an emoji-only
              title OCR cannot read). marks: ink clusters left of the title (dots, chevrons,
              icons, avatars).
- labels:     OCR lines outside every row and header (footers, inline labels, empty states).
- separators: 1 pt AX separator groups (x0) and pixel-scanned hairlines (x0).
"""
import json
import os
import re
import subprocess

ROW_KINDS = {"Button", "CheckBox", "Cell", "PopUpButton", "Switch", "GenericElement", "Link",
             "MenuItem"}
SCREEN_W, SCREEN_H = 402, 874


def _inside(px, py, f, pad=0.5):
    x, y, w, h = f
    return x - pad <= px <= x + w + pad and y - pad <= py <= y + h + pad


def _area(f):
    return f[2] * f[3]


def _round(v):
    return None if v is None else round(v, 1)


def _is_icon_text(e):
    x, y, w, h = e.frame
    return len((e.label or "").strip()) <= 2 and min(w, h) >= 26


def regions(els):
    """(top, bottom) of the content: below the navigation bar, above the tab bar."""
    top = 0
    els = sheet_scope(els)
    for e in els:
        if e.label == "Sheet Grabber":
            top = max(top, e.frame[1] + e.frame[3])
        x, y, w, h = e.frame
        if e.kind == "Heading" and y < 110 and abs(x + w / 2 - SCREEN_W / 2) < 60 and w < 260:
            top = max(top, y + h)
    tab = [e.frame[1] for e in els if e.label == "Tab Bar"]
    bottom = min(tab) if tab else SCREEN_H
    return top, bottom


def sheet_scope(els):
    """With a sheet up, only the sheet's elements (the AX tree lists the screen under it first)."""
    grab = [i for i, e in enumerate(els) if e.label == "Sheet Grabber"]
    return els[grab[-1]:] if grab else els


def visible(els, top, bottom):
    out = []
    for e in sheet_scope(els):
        x, y, w, h = e.frame
        if w <= 0 or h <= 0 or y + h <= top or y >= bottom or x >= SCREEN_W or x + w <= 0:
            continue
        if e.kind in ("Application", "ScrollArea") or e.label == "Tab Bar":
            continue
        if e.kind == "Slider" and "scroll bar" in (e.label or ""):
            continue
        out.append(e)
    return out


def bands_for(els, top, bottom):
    """The bands alignscan scans for ink clusters: each row frame and each child text line."""
    rows, texts = row_candidates(els), [e for e in els if e.kind == "StaticText"]
    bands = []
    for r in rows:
        x, y, w, h = r.frame
        bands.append([max(y, top), min(y + h, bottom), min(x + w, SCREEN_W)])
    for t in texts:
        x, y, w, h = t.frame
        bands.append([max(y, top), min(y + h, bottom), SCREEN_W])
    return rows, texts, bands


def row_candidates(els):
    seen, rows = set(), []
    for e in els:
        x, y, w, h = e.frame
        if not (20 <= h <= 240) or w < 180:
            continue
        # A wide StaticText holding other texts is a row too (LabeledContent).
        holds = e.kind == "StaticText" and w >= 300 and any(
            o is not e and o.kind == "StaticText" and o.frame[2] < w - 20 and _inside(o.center[0], o.center[1], e.frame) for o in els)
        if e.kind not in ROW_KINDS and not holds:
            continue
        key = tuple(round(v) for v in e.frame)
        if key in seen:
            continue
        seen.add(key)
        rows.append(e)
    # A row that holds other rows (a section container) is not a row.
    rows = [r for r in rows if not any(o is not r and _area(o.frame) < _area(r.frame) and
                                       _inside(o.center[0], o.center[1], r.frame) and o.frame[3] >= 20 for o in rows)]
    return rows


def scan(alignscan, png, bands, scale=3):
    r = subprocess.run([alignscan, png, str(scale), json.dumps(bands)], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(f"alignscan failed: {r.stderr[:300]}")
    return json.loads(r.stdout)


def _ink_in(clusters, x_from, x_to=None):
    """First ink cluster that ends right of x_from (+1 pt) and starts before x_to."""
    for c0, c1 in clusters:
        if c1 > x_from + 1 and (x_to is None or c0 < x_to):
            return c0
    return None


def analyze(tree, sc, top, bottom, clip=None):
    els = visible(tree, top, bottom)
    rows, texts, bands = bands_for(els, top, bottom)
    band_clusters = sc.get("bands") or []
    row_cl = band_clusters[:len(rows)]
    text_cl = dict(zip([id(t) for t in texts], band_clusters[len(rows):]))
    ocr = [o for o in sc["ocr"] if top - 2 <= o["y"] + o["h"] / 2 <= bottom]
    if clip:
        ocr = [o for o in ocr if _inside(o["x"] + min(o["w"], 10) / 2, o["y"] + o["h"] / 2, clip)]
    headings = [e for e in els if e.kind == "Heading" and e.label]
    used = set()

    out = {"region": [top, bottom], "headers": [], "rows": [], "labels": [], "separators": {"ax": [], "pixel": []}}

    # Headers.
    for hd in headings:
        lines = [i for i, o in enumerate(ocr) if _inside(o["x"] + min(o["w"], 20) / 2, o["y"] + o["h"] / 2, hd.frame, 2)]
        lines = [i for i in lines if i not in used]
        for i in lines:
            used.add(i)
        inks = [ocr[i].get("ink_x", ocr[i]["x"]) for i in lines]
        out["headers"].append({"text": hd.label, "ax_frame": [_round(v) for v in hd.frame],
                               "ocr": " ".join(ocr[i]["text"] for i in lines) or None,
                               "ink_x": _round(min(inks)) if inks else None})

    # Rows.
    for ri, r in enumerate(rows):
        rx, ry, rw, rh = r.frame
        kids = [t for t in texts if t is not r and _inside(t.center[0], t.center[1], r.frame) and t.frame[2] > 0]
        icons = [t for t in kids if _is_icon_text(t)]
        titles = sorted([t for t in kids if t not in icons and t.frame[0] < rx + rw * 0.62],
                        key=lambda t: (round(t.frame[1] / 4), t.frame[0]))
        lines = sorted([i for i, o in enumerate(ocr) if i not in used and _inside(o["x"] + min(o["w"], 10) / 2, o["y"] + o["h"] / 2, r.frame)],
                       key=lambda i: (ocr[i]["y"], ocr[i]["x"]))
        for i in lines:
            used.add(i)
        rec = {"label": r.label, "kind": r.kind, "ident": r.ident, "frame": [_round(v) for v in r.frame]}
        clusters = row_cl[ri] if ri < len(row_cl) else []
        if titles:
            t = titles[0]
            tx = t.frame[0]
            tcl = text_cl.get(id(t), [])
            ink = _ink_in(tcl, tx, tx + t.frame[2])
            line = next((ocr[i] for i in lines if abs(ocr[i]["y"] + ocr[i]["h"] / 2 - t.center[1]) < max(6, t.frame[3] / 2)
                         and ocr[i]["x"] < tx + t.frame[2]), None)
            rec.update(title=t.label, title_ax_x=_round(tx), title_ink_x=_round(ink),
                       title_ocr_ink_x=_round(line.get("ink_x")) if line else None, source="ax")
            subs = [s for s in titles[1:] if s.frame[1] > t.frame[1] + t.frame[3] - 2]
            if subs:
                s = subs[0]
                rec.update(subtitle=s.label, subtitle_ax_x=_round(s.frame[0]),
                           subtitle_ink_x=_round(_ink_in(text_cl.get(id(s), []), s.frame[0], s.frame[0] + s.frame[2])))
        else:
            cand = [i for i in lines if ocr[i]["x"] < rx + rw * 0.62]
            if cand:
                o = ocr[cand[0]]
                rec.update(title=o["text"], title_ax_x=None, title_ink_x=_round(o.get("ink_x", o["x"])), source="ocr")
                if len(cand) > 1:
                    s = ocr[cand[1]]
                    if s["y"] > o["y"] + o["h"] * 0.6:
                        rec.update(subtitle=s["text"], subtitle_ink_x=_round(s.get("ink_x", s["x"])))
            else:
                rec.update(title=None, title_ink_x=None, source="none")
        tix = rec.get("title_ink_x") or rec.get("title_ax_x")
        if tix is not None:
            rec["marks"] = [c for c in clusters if c[1] <= tix - 1 and c[0] >= rx - 1]
        rec["icons_ax"] = [{"label": i.label, "x": _round(i.frame[0])} for i in icons]
        rec["images_ax"] = [{"label": e.label or e.ident, "x": _round(e.frame[0])} for e in els
                            if e.kind == "Image" and _inside(e.center[0], e.center[1], r.frame) and tix is not None and e.frame[0] < tix]
        out["rows"].append(rec)

    # Loose labels (footers, inline labels, empty states).
    for i, o in enumerate(ocr):
        if i in used:
            continue
        cx, cy = o["x"] + min(o["w"], 10) / 2, o["y"] + o["h"] / 2
        if any(_inside(cx, cy, e.frame) for e in rows):
            continue
        ax = next((t for t in texts if _inside(cx, cy, t.frame, 2)), None)
        out["labels"].append({"text": o["text"], "ink_x": _round(o.get("ink_x", o["x"])),
                              "ax_x": _round(ax.frame[0]) if ax else None, "y": _round(o["y"])})

    for e in els:
        x, y, w, h = e.frame
        if e.kind == "Group" and not e.label and h <= 1.5 and w >= 60:
            out["separators"]["ax"].append({"x0": _round(x), "x1": _round(x + w), "y": _round(y)})
    for s in sc.get("separators") or []:
        if top <= s["y"] <= bottom:
            out["separators"]["pixel"].append(s)
    return out


def summary(m):
    """Compact per-screen numbers: header x's, row title x's, gutter mark x's, separator x0's."""
    def uniq(vals):
        return sorted({v for v in vals if v is not None})
    rows = m["rows"]
    return {
        "headers": [(h["text"], h["ink_x"]) for h in m["headers"]],
        "header_x": uniq(h["ink_x"] for h in m["headers"]),
        "row_title_x": uniq(r.get("title_ink_x") for r in rows),
        "row_title_ax_x": uniq(r.get("title_ax_x") for r in rows),
        "row_subtitle_x": uniq(r.get("subtitle_ink_x") for r in rows),
        "mark_x": uniq(c[0] for r in rows for c in r.get("marks", [])),
        "label_x": uniq(l["ink_x"] for l in m["labels"]),
        "separator_x0": uniq([s["x0"] for s in m["separators"]["ax"]] + [s["x0"] for s in m["separators"]["pixel"]]),
        "rows": [(r.get("title"), r.get("title_ink_x"), [c[0] for c in r.get("marks", [])]) for r in rows],
        "labels": [(l["text"][:40], l["ink_x"]) for l in m["labels"]],
    }
