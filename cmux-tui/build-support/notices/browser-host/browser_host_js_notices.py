#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Notice rows for the third-party JavaScript that cmux-browser-host embeds.

  browser_host_js_notices.py check [--repo DIR]

cmux-browser-host's build.rs embeds (include_str!) every file that
js/manifest.json lists, so the vendored acorn and Playwright code ships inside
bin/cmux-browser-host. browser-host-js.json holds one reviewed row per file of
js/vendor. `check` fails closed when a vendor file has no row, a row names a
file that is gone or that the manifest does not embed, a file no longer matches
its marker (a new upstream version), a stored text differs from its sha256, an
embedded file outside js/vendor names a third-party origin, or hand-written.md's
section lacks a row's path or text. Python 3.11+ standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
MANIFEST = HERE / "browser-host-js.json"
SECTION = "cmux browser host runtime JavaScript"
VENDOR = "vendor/"
# A first-party runtime file that says this marks copied third-party code; it
# belongs in js/vendor with a reviewed row.
FOREIGN = re.compile(r"(?i)\b(?:vendored|adapted|ported|derived) from\b|\blicensed under\b|\bSPDX-License-Identifier\b|\bcopyright \(c\)")


class NoticeError(RuntimeError):
    pass


def load(path: Path = MANIFEST) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def text(manifest: dict, name: str, base: Path = HERE) -> str:
    entry = manifest["texts"][name]
    data = (base / entry["file"]).read_bytes()
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise NoticeError(f"{entry['file']}: sha256 differs from browser-host-js.json")
    # The notice prints the text with LF line endings (Playwright's LICENSE is CRLF).
    return data.decode("utf-8").replace("\r\n", "\n")


def embedded(js_dir: Path) -> list[str]:
    """Every file js/manifest.json lists (build.rs embeds them all)."""
    lists = json.loads((js_dir / "manifest.json").read_text(encoding="utf-8"))
    return sorted({name for files in lists.values() for name in files})


def problems(manifest: dict, js_dir: Path, hand_written: str, base: Path = HERE) -> list[str]:
    rows = manifest["files"]
    errors = []
    vendor = sorted(p.relative_to(js_dir).as_posix() for p in (js_dir / VENDOR).rglob("*") if p.is_file())
    listed = embedded(js_dir)
    for path in sorted(set(vendor) - set(rows)):
        errors.append(
            f"js/{path} is vendored but browser-host-js.json has no row: review its origin and license, "
            f"add the row and its text, and name it in hand-written.md's '{SECTION}' section"
        )
    for path in sorted(set(rows) - set(vendor)):
        errors.append(f"browser-host-js.json has a row for js/{path}, which is gone; remove it")
    for path in sorted(set(rows) & set(vendor)):
        if path not in listed:
            errors.append(f"js/{path} has a row but js/manifest.json does not embed it; remove the file or list it")
        marker = rows[path].get("marker", "")
        content = (js_dir / path).read_text(encoding="utf-8", errors="replace")
        if not marker or not re.search(marker, content, re.M):
            errors.append(
                f"js/{path} no longer matches its reviewed marker {marker!r} (a new upstream version?): "
                "review the file's license and update its row and texts"
            )
    for path in listed:
        if path.startswith(VENDOR):
            continue
        source = js_dir / path
        if source.is_file() and FOREIGN.search(source.read_text(encoding="utf-8", errors="replace")):
            errors.append(f"js/{path} names a third-party origin or license; move the code to js/vendor with a reviewed row")
    try:
        section = hand_written_section(hand_written)
    except NoticeError as error:
        return errors + [str(error)]
    for path, row in sorted(rows.items()):
        if f"`{path}`" not in section:
            errors.append(f"hand-written.md section '{SECTION}' does not name `{path}`")
        for name in row["texts"]:
            try:
                body = text(manifest, name, base).rstrip("\n")
            except (NoticeError, KeyError) as error:
                errors.append(f"{path}: text {name}: {error}")
                continue
            if f"```text\n{body}\n```" not in section:
                errors.append(f"hand-written.md section '{SECTION}' lacks the {name} text unchanged (in a text block)")
    return errors


def hand_written_section(hand_written: str) -> str:
    match = re.search(rf"^## {re.escape(SECTION)}\n(.*?)(?=^## |\Z)", hand_written, re.S | re.M)
    if not match:
        raise NoticeError(f"hand-written.md has no section '{SECTION}'")
    return match.group(1)


def check_repository(repo: Path = ROOT) -> list[str]:
    manifest = load()
    js_dir = repo / manifest["crate"] / "js"
    return problems(manifest, js_dir, (repo / "scripts/cmux-next/notices/hand-written.md").read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check")
    check.add_argument("--repo", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        errors = check_repository(args.repo)
    except (NoticeError, OSError, ValueError) as error:
        print(f"browser_host_js_notices: error: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"browser_host_js_notices: error: {error}", file=sys.stderr)
    if not errors:
        print("browser_host_js_notices: every embedded third-party browser host script has a reviewed notice row")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
