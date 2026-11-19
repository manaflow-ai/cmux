#!/usr/bin/env python3
"""Prints each source's metrics, axes, masters and GSUB features as JSON: what the face builds start from."""

from __future__ import annotations

import json
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))

import common  # noqa: E402

out = {}
for name in json.loads((common.SOURCES / "SOURCES.json").read_text())["files"]:
    font = common.source(name)
    gvar = font["gvar"]
    peaks = set()
    for variations in gvar.variations.values():
        for v in variations:
            peaks.add(tuple(sorted((t, round(p[1], 3)) for t, p in v.axes.items())))
    info = common.report(font)
    info["sxHeight"] = font["OS/2"].sxHeight
    info["sCapHeight"] = font["OS/2"].sCapHeight
    info["typo"] = [font["OS/2"].sTypoAscender, font["OS/2"].sTypoDescender, font["OS/2"].sTypoLineGap]
    info["peaks"] = sorted(peaks)
    info["instances"] = [i.coordinates for i in font["fvar"].instances]
    info["features"] = common.features(font)
    info["tables"] = sorted(font.keys())
    info["latin_woff2_before"] = common.woff2_size_of_source_subset(name)
    out[name] = info
print(json.dumps(out, indent=1, default=str))
