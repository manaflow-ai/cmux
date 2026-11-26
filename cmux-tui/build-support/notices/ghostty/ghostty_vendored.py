#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Coverage of the vendored directories of a Ghostty tree (pkg/*, vendor/*).

Ghostty keeps third-party code in its own tree too, not only in fetched Zig
packages: pkg/simdutf/vendor/ holds the simdutf amalgamation, vendor/glad the
generated glad loader. Such a directory has no license file, so the Zig package
collection never saw it and no notice shipped its terms. This module is the one
shared check (cmux-next and cmux-browser, through collect-ghostty-licenses.py):

A directory pkg/<name> or vendor/<name> that has a license file anywhere in it
is covered by that file (the collector ships it). Any other one needs an entry
under "vendored" in pinned-licenses/MANIFEST.json, keyed by its path:

  "pkg/simdutf": {
    "covered_by": "ghostty" | "zig-dependency:<name>" | "pinned:<packages key>",
    "files": {"<path in the directory>": "<sha256>" | ["<sha256>", ...] | "*"},
    "note": "why this coverage is right"
  }

- ghostty: Ghostty's own code (its MIT LICENSE ships with every tree).
- zig-dependency:<name>: files derived from a package that the directory's
  build.zig.zon declares as <name>; the collected license of that fetched
  package covers them.
- pinned:<key>: third-party code with no fetched package; the texts of
  "packages"."<key>" ship from pinned-licenses/.
"files" names every file of the directory except *.zig and *.zon, each with
the sha256 values reviewed (several versions may be listed). "*" (any content)
is allowed only for covered_by "ghostty" with a note that gives the reason.
An unlisted directory, an unlisted file, an unreviewed content or an
undeclared dependency is a problem: collection fails until the directory is
reviewed and pinned in pinned-licenses/MANIFEST.json.

CLI (no zig, no network): check one tree from a checkout or a git revision.
  ghostty_vendored.py --source <ghostty checkout>
  ghostty_vendored.py --git-dir <ghostty repo> --rev <commit>
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Callable, Iterable

HERE = Path(__file__).resolve().parent
VENDORED_ROOTS = ("pkg", "vendor")
# The collector's license file names (collect-ghostty-licenses.py LICENSE_NAME).
LICENSE_NAME = re.compile(
    r"^(license|licence|copying|copyright|notice|authors|ofl|unlicense)"
    r"([._-].*)?$",
    re.IGNORECASE,
)
SHA256 = re.compile(r"[0-9a-f]{64}")
ZON_DEPENDENCY = re.compile(r'\.(@"[^"\\]+"|[A-Za-z_][A-Za-z0-9_]*)\s*=\s*\.\{([^{}]*)\}')
ZON_SOURCE = re.compile(r'\.(url|path)\s*=\s*"')
PIN_HINT = (
    "review it and pin it under \"vendored\" in "
    "cmux-tui/build-support/notices/ghostty/pinned-licenses/MANIFEST.json"
)


class Tree:
    """Read-only view of a Ghostty tree: a checkout or a git revision."""

    def __init__(self, files: Iterable[str], read: Callable[[str], bytes]) -> None:
        self.files = sorted(files)
        self.read = read

    @classmethod
    def from_directory(cls, root: Path) -> "Tree":
        files = []
        for top in VENDORED_ROOTS:
            base = root / top
            if not base.is_dir():
                continue
            for path in base.rglob("*"):
                relative = path.relative_to(root)
                if path.is_file() and ".git" not in relative.parts:
                    files.append(relative.as_posix())
        return cls(files, lambda path: (root / path).read_bytes())

    @classmethod
    def from_git(cls, git_dir: Path, revision: str) -> "Tree":
        listed = subprocess.run(
            ["git", "-C", str(git_dir), "ls-tree", "-r", "--name-only", revision, "--", *VENDORED_ROOTS],
            check=True, capture_output=True, text=True,
        ).stdout.splitlines()

        def read(path: str) -> bytes:
            return subprocess.run(
                ["git", "-C", str(git_dir), "show", f"{revision}:{path}"],
                check=True, capture_output=True,
            ).stdout

        return cls(listed, read)

    def directories(self) -> dict[str, list[str]]:
        """pkg/<name> and vendor/<name> -> the paths of their files."""
        found: dict[str, list[str]] = {}
        for path in self.files:
            parts = path.split("/")
            if len(parts) >= 3 and parts[0] in VENDORED_ROOTS:
                found.setdefault("/".join(parts[:2]), []).append("/".join(parts[2:]))
        return found


def strip_zon_comments(text: str) -> str:
    lines = []
    for line in text.splitlines():
        in_string = escaped = False
        cut = len(line)
        for index, character in enumerate(line):
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
            elif character == '"':
                in_string = True
            elif line.startswith("//", index):
                cut = index
                break
        lines.append(line[:cut])
    return "\n".join(lines)


def declared_dependencies(zon: bytes) -> set[str]:
    text = strip_zon_comments(zon.decode("utf-8", errors="replace"))
    names = set()
    for raw, body in ZON_DEPENDENCY.findall(text):
        if ZON_SOURCE.search(body):
            names.add(raw[2:-1] if raw.startswith('@"') else raw)
    return names


def validate_entries(vendored: dict, packages: dict) -> None:
    """Raise ValueError for a malformed "vendored" section."""
    if not isinstance(vendored, dict):
        raise ValueError("\"vendored\" must be an object")
    for key, entry in vendored.items():
        parts = key.split("/")
        if len(parts) != 2 or parts[0] not in VENDORED_ROOTS or not parts[1]:
            raise ValueError(f"vendored key must be pkg/<name> or vendor/<name>: {key}")
        if not isinstance(entry, dict) or set(entry) != {"covered_by", "files", "note"}:
            raise ValueError(f"vendored {key}: expected covered_by, files and note")
        if not isinstance(entry["note"], str) or not entry["note"].strip():
            raise ValueError(f"vendored {key}: the note must give the reason")
        covered_by = entry["covered_by"]
        kind, _, value = covered_by.partition(":")
        if covered_by != "ghostty" and not (kind in ("zig-dependency", "pinned") and value):
            raise ValueError(f"vendored {key}: unknown covered_by {covered_by!r}")
        if kind == "pinned" and value not in packages:
            raise ValueError(f"vendored {key}: pinned:{value} names no \"packages\" entry")
        if not isinstance(entry["files"], dict):
            raise ValueError(f"vendored {key}: files must be an object")
        for name, digests in entry["files"].items():
            if digests == "*":
                if covered_by != "ghostty":
                    raise ValueError(
                        f"vendored {key}/{name}: \"*\" is allowed only for covered_by ghostty"
                    )
                continue
            values = [digests] if isinstance(digests, str) else digests
            if not isinstance(values, list) or not values or not all(
                isinstance(value, str) and SHA256.fullmatch(value) for value in values
            ):
                raise ValueError(f"vendored {key}/{name}: expected sha256 values")


def check_tree(tree: Tree, vendored: dict) -> tuple[list[str], list[tuple[str, str]]]:
    """(problems, [(directory, pinned packages key)]) for one Ghostty tree."""
    problems: list[str] = []
    pinned: list[tuple[str, str]] = []
    for directory, files in sorted(tree.directories().items()):
        if any(LICENSE_NAME.match(name.rsplit("/", 1)[-1]) for name in files):
            continue
        entry = vendored.get(directory)
        if entry is None:
            problems.append(f"{directory}: no license file and no \"vendored\" entry; {PIN_HINT}")
            continue
        for name in files:
            if name.endswith((".zig", ".zon")):
                continue
            reviewed = entry["files"].get(name)
            if reviewed is None:
                problems.append(f"{directory}/{name}: file not reviewed; {PIN_HINT}")
                continue
            if reviewed == "*":
                continue
            digest = hashlib.sha256(tree.read(f"{directory}/{name}")).hexdigest()
            if digest not in ([reviewed] if isinstance(reviewed, str) else reviewed):
                problems.append(
                    f"{directory}/{name}: content {digest} is not a reviewed version; {PIN_HINT}"
                )
        kind, _, value = entry["covered_by"].partition(":")
        if kind == "zig-dependency":
            zon = f"{directory}/build.zig.zon"
            declared = declared_dependencies(tree.read(zon)) if zon[len(directory) + 1:] in files else set()
            if value not in declared:
                problems.append(f"{directory}: build.zig.zon declares no dependency {value!r}; {PIN_HINT}")
        elif kind == "pinned":
            pinned.append((directory, value))
    return problems, pinned


def load_manifest(path: Path) -> tuple[dict, dict]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    packages, vendored = manifest["packages"], manifest.get("vendored", {})
    validate_entries(vendored, packages)
    return packages, vendored


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, help="a Ghostty checkout")
    parser.add_argument("--git-dir", type=Path, help="a Ghostty git repository (with --rev)")
    parser.add_argument("--rev", help="the Ghostty commit to check in --git-dir")
    parser.add_argument("--manifest", type=Path, default=HERE / "pinned-licenses/MANIFEST.json")
    args = parser.parse_args(argv)
    if (args.source is None) == (args.git_dir is None) or (args.git_dir is not None) != (args.rev is not None):
        parser.error("pass --source, or --git-dir with --rev")
    _, vendored = load_manifest(args.manifest)
    tree = Tree.from_directory(args.source) if args.source else Tree.from_git(args.git_dir, args.rev)
    problems, pinned = check_tree(tree, vendored)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        return 1
    label = args.source or f"{args.git_dir}@{args.rev}"
    print(f"vendored Ghostty directories covered in {label} ({len(pinned)} with pinned texts)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
