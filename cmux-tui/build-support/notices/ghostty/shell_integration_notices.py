#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Notice rows for Ghostty's shell integration files that cmux ships.

  shell_integration_notices.py check [--repo DIR] [--ghostty-next-git-dir DIR]

The cmux-next app bundles ghostty-next/src/shell-integration
(scripts/cmux-next/bundle-ghostty-resources.sh) and cmux-tui embeds some of its
files with include_str! (every target). shell-integration.json holds one reviewed
row per file. `check` fails closed when a file at the ghostty-next gitlink has no
row, a row names a file that is gone, a file no longer matches its marker (for
example a new bash-preexec version), a stored text differs from its sha256, the
embedded flags differ from the include_str!/include_bytes! set, cmux-tui embeds
shell integration from another tree, or hand-written.md's "Ghostty shell
integration" section lacks a row's path or text. package_notices.py and the app
notices read the same rows. Python 3.11+ standard library and git only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
MANIFEST = HERE / "shell-integration.json"
HAND_WRITTEN = ROOT / "scripts/cmux-next/notices/hand-written.md"
SECTION = "Ghostty shell integration"
PREFIX = "src/shell-integration/"
INCLUDE = re.compile(r"include_(?:str|bytes)!\s*\(\s*\"([^\"]*?([A-Za-z0-9_-]+)/src/shell-integration/([^\"]+))\"", re.S)


class NoticeError(RuntimeError):
    pass


def load(path: Path = MANIFEST) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def text(manifest: dict, name: str) -> str:
    entry = manifest["texts"][name]
    data = (MANIFEST.parent / entry["file"]).read_bytes()
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise NoticeError(f"{entry['file']}: sha256 differs from shell-integration.json")
    return data.decode("utf-8")


def read_tree(git_dir: Path, revision: str) -> dict[str, str]:
    """path (relative to src/shell-integration) -> content, from git at `revision`."""
    names = subprocess.run(
        ["git", "-C", str(git_dir), "ls-tree", "-r", "--name-only", revision, PREFIX],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    return {
        name[len(PREFIX):]: subprocess.run(
            ["git", "-C", str(git_dir), "show", f"{revision}:{name}"], check=True, capture_output=True
        ).stdout.decode("utf-8", "replace")
        for name in names
    }


def embedded_paths(rust_root: Path) -> set[tuple[str, str]]:
    """(tree, path) for every include_str!/include_bytes! of a shell-integration file."""
    found = set()
    for source in sorted(rust_root.rglob("*.rs")):
        if "/target/" in source.as_posix():
            continue
        for match in INCLUDE.finditer(source.read_text(encoding="utf-8", errors="replace")):
            found.add((match.group(2), match.group(3)))
    return found


def problems(manifest: dict, files: dict[str, str], embedded: set[tuple[str, str]], hand_written: str) -> list[str]:
    rows = manifest["files"]
    errors = []
    for path in sorted(set(files) - set(rows)):
        errors.append(
            f"ghostty-next {PREFIX}{path} ships (app bundle) but shell-integration.json has no row: review its "
            "origin and license, add the row and its text, and name it in hand-written.md's "
            f"'{SECTION}' section"
        )
    for path in sorted(set(rows) - set(files)):
        errors.append(f"shell-integration.json has a row for {path}, which ghostty-next no longer has; remove it")
    for path in sorted(set(rows) & set(files)):
        marker = rows[path].get("marker", "")
        if marker and not re.search(marker, files[path]):
            errors.append(
                f"{PREFIX}{path} no longer matches its reviewed marker {marker!r} (a new upstream version?): "
                "review the file's license and update its row and text"
            )
    for tree, path in sorted(embedded):
        if tree != manifest["source"]:
            errors.append(f"cmux-tui embeds {tree}/src/shell-integration/{path}; only {manifest['source']} is reviewed")
    included = {path for tree, path in embedded if tree == manifest["source"]}
    flagged = {path for path, row in rows.items() if row.get("embedded")}
    for path in sorted(included - flagged):
        errors.append(f"cmux-tui embeds {path} with include_str!, but its row has embedded=false (package notices omit it)")
    for path in sorted(flagged - included):
        errors.append(f"the row for {path} says embedded=true, but cmux-tui does not embed it")
    try:
        section = hand_written_section(hand_written)
    except NoticeError as error:
        return errors + [str(error)]
    for path, row in sorted(rows.items()):
        if f"`{path}`" not in section:
            errors.append(f"hand-written.md section '{SECTION}' does not name `{path}`")
        if row["text"] in manifest["texts"]:
            try:
                body = text(manifest, row["text"]).rstrip("\n")
            except NoticeError as error:
                errors.append(str(error))
                continue
            if f"```text\n{body}\n```" not in section:
                errors.append(f"hand-written.md section '{SECTION}' lacks the {row['text']} text unchanged (in a text block)")
    return errors


def hand_written_section(hand_written: str) -> str:
    match = re.search(rf"^## {re.escape(SECTION)}\n(.*?)(?=^## |\Z)", hand_written, re.S | re.M)
    if not match:
        raise NoticeError(f"hand-written.md has no section '{SECTION}'")
    return match.group(1)


def check_repository(repo: Path = ROOT, git_dir: Path | None = None) -> list[str]:
    manifest = load()
    source = manifest["source"]
    revision = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", f"HEAD:{source}"], check=True, capture_output=True, text=True
    ).stdout.strip()
    files = read_tree(git_dir or repo / source, revision)
    return problems(manifest, files, embedded_paths(repo / "cmux-tui"), (repo / "scripts/cmux-next/notices/hand-written.md").read_text())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check")
    check.add_argument("--repo", type=Path, default=ROOT)
    check.add_argument("--ghostty-next-git-dir", type=Path)
    args = parser.parse_args(argv)
    try:
        errors = check_repository(args.repo, args.ghostty_next_git_dir)
    except (NoticeError, subprocess.CalledProcessError) as error:
        print(f"shell_integration_notices: error: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"shell_integration_notices: error: {error}", file=sys.stderr)
    if not errors:
        print(f"shell_integration_notices: every shipped shell integration file has a reviewed notice row")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
