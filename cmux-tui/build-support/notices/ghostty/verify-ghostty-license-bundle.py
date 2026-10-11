#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify one collected Ghostty dependency-license tree fail closed.

Moved verbatim from manaflow-ai/cmux-browser scripts/verify-ghostty-license-bundle.py
at cc93624d; shared with cmux-browser through cmux-tui/build-support.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_LICENSE_BYTES = 2 * 1024 * 1024
# Windows installers unpack below a ~100-character temp prefix; a deep tree
# here is what exceeded MAX_PATH in production run 33259127761. The collector
# emits `<label>/<hash12>-<basename>` destinations, so anything longer than
# this is a layout regression.
MAX_DESTINATION_CHARS = 80
EXPECTED_MANIFEST_KEYS = {
    "ghostty_revision",
    "license_files",
    "schema",
    "unresolved_packages",
}
EXPECTED_ENTRY_KEYS = {
    "bytes",
    "destination",
    "package",
    "sha256",
    "source",
    "source_kind",
}
# Optional: manifests collected before the Zig package index have no
# `zig_packages`; their packages keep directory names in the SPDX inventory.
OPTIONAL_MANIFEST_KEYS = {"zig_packages"}
SOURCE_KINDS = {
    "generated-source-offer",
    "ghostty",
    "verified-upstream-license",
    "zig-cache",
}
ZIG_PACKAGE_KEYS = {"dependency", "url"}
DEPENDENCY_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")


class VerificationError(ValueError):
    """The collected notice tree is incomplete or internally inconsistent."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def regular_files(root: Path) -> set[str]:
    result: set[str] = set()
    for directory, directory_names, file_names in os.walk(
        root, topdown=True, followlinks=False
    ):
        directory_path = Path(directory)
        for name in directory_names:
            path = directory_path / name
            require(not path.is_symlink(), f"license tree contains a symlink: {path}")
            require(
                stat.S_ISDIR(path.stat(follow_symlinks=False).st_mode),
                f"license tree contains a non-directory entry: {path}",
            )
        for name in file_names:
            path = directory_path / name
            metadata = path.stat(follow_symlinks=False)
            require(
                stat.S_ISREG(metadata.st_mode),
                f"license tree contains a non-regular file: {path}",
            )
            result.add(path.relative_to(root).as_posix())
    return result


def verify(root: Path, revision: str) -> int:
    require(re.fullmatch(r"[0-9a-f]{40}", revision) is not None,
            "expected Ghostty revision must be a lowercase 40-hex commit")
    require(root.is_dir() and not root.is_symlink(),
            f"Ghostty dependency license root is unsafe or missing: {root}")

    manifest_path = root / "SOURCE-MANIFEST.json"
    require(manifest_path.is_file() and not manifest_path.is_symlink(),
            f"Ghostty dependency license manifest is unsafe or missing: {manifest_path}")
    require(manifest_path.stat().st_size <= MAX_MANIFEST_BYTES,
            "Ghostty dependency license manifest is unexpectedly large")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(
            f"Ghostty dependency license manifest is invalid: {error}"
        ) from error

    require(isinstance(manifest, dict) and
            EXPECTED_MANIFEST_KEYS <= set(manifest) <=
            EXPECTED_MANIFEST_KEYS | OPTIONAL_MANIFEST_KEYS,
            "Ghostty dependency license manifest has unexpected fields")
    require(manifest.get("schema") == 1,
            "unsupported Ghostty dependency license manifest schema")
    require(manifest.get("ghostty_revision") == revision,
            "Ghostty dependency license revision differs from the product pin")
    require(manifest.get("unresolved_packages") == [],
            "Ghostty dependency license inventory has unresolved packages")
    entries = manifest.get("license_files")
    require(isinstance(entries, list) and len(entries) >= 5,
            "Ghostty dependency license inventory is unexpectedly small")

    # Reject link-like or special entries before following any manifest path.
    actual_files = regular_files(root)
    actual_files.discard("SOURCE-MANIFEST.json")
    expected_files: set[str] = set()
    for index, entry in enumerate(entries):
        label = f"Ghostty dependency license entry {index}"
        require(isinstance(entry, dict) and set(entry) == EXPECTED_ENTRY_KEYS,
                f"{label} has unexpected fields")
        destination = entry.get("destination")
        require(isinstance(destination, str) and destination != "" and
                "\\" not in destination,
                f"{label} has an invalid destination")
        relative = PurePosixPath(destination)
        require(not relative.is_absolute() and ".." not in relative.parts and
                str(relative) == destination and
                destination != "SOURCE-MANIFEST.json",
                f"{label} has an unsafe destination: {destination}")
        require(destination not in expected_files,
                f"duplicate Ghostty dependency license destination: {destination}")
        require(len(destination) <= MAX_DESTINATION_CHARS,
                f"{label} destination exceeds the {MAX_DESTINATION_CHARS}-char "
                f"extraction budget: {destination}")
        expected_files.add(destination)

        byte_count = entry.get("bytes")
        require(isinstance(byte_count, int) and not isinstance(byte_count, bool) and
                0 < byte_count <= MAX_LICENSE_BYTES,
                f"{label} has an invalid byte count")
        expected_sha256 = entry.get("sha256")
        require(isinstance(expected_sha256, str) and
                re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is not None,
                f"{label} has an invalid SHA-256")
        require(isinstance(entry.get("package"), str) and bool(entry["package"]),
                f"{label} has an invalid package")
        require(isinstance(entry.get("source"), str) and bool(entry["source"]),
                f"{label} has an invalid source")
        require(entry.get("source_kind") in SOURCE_KINDS,
                f"{label} has an invalid source kind")

        target = root.joinpath(*relative.parts)
        require(target.is_file() and not target.is_symlink(),
                f"Ghostty dependency license file is unsafe or missing: {destination}")
        require(target.stat().st_size == byte_count,
                f"Ghostty dependency license size mismatch: {destination}")
        require(sha256(target) == expected_sha256,
                f"Ghostty dependency license digest mismatch: {destination}")

    require(actual_files == expected_files,
            "Ghostty dependency license files differ from the manifest")
    verify_zig_packages(manifest.get("zig_packages", {}), entries)
    return len(entries)


def verify_zig_packages(index: object, entries: list[dict]) -> None:
    """Every indexed Zig package must own license files in this tree."""
    require(isinstance(index, dict),
            "Ghostty Zig package index is not an object")
    directories = set()
    for entry in entries:
        if entry["source_kind"] != "ghostty":
            directories.add(entry["package"])
        else:
            parts = entry["source"].split("/")
            if len(parts) > 2 and parts[0] == "zig-pkg":
                directories.add(parts[1])
    for directory, value in index.items():
        label = f"Ghostty Zig package index entry {directory!r}"
        require(directory in directories,
                f"{label} has no license files in the manifest")
        require(isinstance(value, dict) and set(value) == ZIG_PACKAGE_KEYS,
                f"{label} has unexpected fields")
        require(isinstance(value["dependency"], str) and
                DEPENDENCY_NAME.fullmatch(value["dependency"]) is not None,
                f"{label} has an invalid dependency name")
        require(isinstance(value["url"], str) and
                not any(character.isspace() for character in value["url"]),
                f"{label} has an invalid URL")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    try:
        count = verify(args.root, args.revision)
    except (OSError, VerificationError) as error:
        parser.error(str(error))
    print(f"verified {count} Ghostty dependency license files in {args.root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
