"""Side-by-side BEFORE / AFTER table from two measure.py result folders.

    python3 compare.py BEFORE_DIR AFTER_DIR > compare.md

Per variant (appearance-size) and screen: header x's, row title x's, gutter mark x's,
label x's and separator x0's, before -> after, and the header-to-title gap (header x minus
the most common row title x; 0 means aligned).
"""
import collections
import json
import os
import sys


def load(d):
    return json.load(open(os.path.join(d, "results.json")))["results"]


def mode(vals):
    vals = [round(v) for v in vals if v is not None]
    return collections.Counter(vals).most_common(1)[0][0] if vals else None


def fmt(vals, n=6):
    vals = sorted({round(v) for v in vals if v is not None})
    return ", ".join(map(str, vals[:n])) + ("…" if len(vals) > n else "") if vals else "-"


def gap(s):
    t = mode([r[1] for r in s["rows"]])
    hs = [x for _, x in s["headers"] if x is not None]
    return None if t is None or not hs else ", ".join(str(round(h - t)) for h in sorted({round(h) for h in hs}))


def main():
    before, after = load(sys.argv[1]), load(sys.argv[2])
    out = ["# List alignment, before vs after", "",
           "x in points. Each cell is `before → after`. *gap*: header x minus the most common row title x "
           "(0 = headers on the text column).", ""]
    for variant in before:
        out += [f"## {variant}", "", "| screen | headers | row titles | gap | marks | labels | separators |",
                "| --- | --- | --- | --- | --- | --- | --- |"]
        screens = list(before[variant]) + [s for s in after.get(variant, {}) if s not in before[variant]]
        for name in screens:
            b, a = before[variant].get(name, {}), after.get(variant, {}).get(name, {})
            if "summary" not in b or "summary" not in a:
                why = b.get("skipped") or a.get("skipped") or "missing"
                out.append(f"| {name} | {why} | | | | | |")
                continue
            sb, sa = b["summary"], a["summary"]
            cells = [f"{fmt(sb[k])} → {fmt(sa[k])}" for k in ("header_x", "row_title_x")]
            cells.append(f"{gap(sb) or '-'} → {gap(sa) or '-'}")
            cells += [f"{fmt(sb[k])} → {fmt(sa[k])}" for k in ("mark_x", "label_x", "separator_x0")]
            out.append(f"| {name} | " + " | ".join(cells) + " |")
        out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
