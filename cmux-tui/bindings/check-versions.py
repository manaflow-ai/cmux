#!/usr/bin/env python3
"""Require every versioned cmux-tui SDK package to use one release version."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path


BINDINGS = Path(__file__).resolve().parent


def read_versions() -> dict[str, str]:
    typescript = json.loads(
        (BINDINGS / "typescript/package.json").read_text(encoding="utf-8")
    )["version"]
    python = tomllib.loads(
        (BINDINGS / "python/pyproject.toml").read_text(encoding="utf-8")
    )["project"]["version"]
    rust = tomllib.loads(
        (BINDINGS / "rust/Cargo.toml").read_text(encoding="utf-8")
    )["package"]["version"]

    java_root = ET.parse(BINDINGS / "java/pom.xml").getroot()
    java = java_root.findtext("{http://maven.apache.org/POM/4.0.0}version")
    if java is None:
        raise ValueError("java/pom.xml has no project version")

    cpp_source = (BINDINGS / "cpp/CMakeLists.txt").read_text(encoding="utf-8")
    cpp_match = re.search(
        r"(?m)^project\(cmux_tui_sdk VERSION ([0-9]+\.[0-9]+\.[0-9]+) ",
        cpp_source,
    )
    if cpp_match is None:
        raise ValueError("cpp/CMakeLists.txt has no cmux_tui_sdk project version")

    zig_source = (BINDINGS / "zig/build.zig").read_text(encoding="utf-8")
    zig_match = re.search(
        r'SemanticVersion\.parse\("([0-9]+\.[0-9]+\.[0-9]+)"\)',
        zig_source,
    )
    if zig_match is None:
        raise ValueError("zig/build.zig has no SDK semantic version")

    return {
        "typescript": str(typescript),
        "python": str(python),
        "rust": str(rust),
        "java": java,
        "cpp": cpp_match.group(1),
        "zig": zig_match.group(1),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", help="require this X.Y.Z release version")
    arguments = parser.parse_args(argv)
    try:
        versions = read_versions()
    except (OSError, KeyError, ValueError, ET.ParseError) as error:
        print(f"SDK version error: {error}", file=sys.stderr)
        return 1

    distinct = set(versions.values())
    if len(distinct) != 1:
        for language, version in sorted(versions.items()):
            print(f"{language}: {version}", file=sys.stderr)
        print("SDK version error: package versions differ", file=sys.stderr)
        return 1
    version = distinct.pop()
    if arguments.expected is not None and version != arguments.expected:
        print(
            f"SDK version error: expected {arguments.expected}, found {version}",
            file=sys.stderr,
        )
        return 1
    print(
        f"SDK versions ok: {version} "
        f"({', '.join(sorted(versions))}; Go follows the shared Git tag)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
