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


def read_versions(bindings: Path = BINDINGS) -> dict[str, str]:
    typescript = json.loads(
        (bindings / "typescript/package.json").read_text(encoding="utf-8")
    )["version"]
    python = tomllib.loads(
        (bindings / "python/pyproject.toml").read_text(encoding="utf-8")
    )["project"]["version"]
    rust = tomllib.loads(
        (bindings / "rust/Cargo.toml").read_text(encoding="utf-8")
    )["package"]["version"]
    rust_sidebar_manifest = tomllib.loads(
        (bindings / "rust-sidebar/Cargo.toml").read_text(encoding="utf-8")
    )
    rust_sidebar = rust_sidebar_manifest["package"]["version"]

    java_root = ET.parse(bindings / "java/pom.xml").getroot()
    java = java_root.findtext("{http://maven.apache.org/POM/4.0.0}version")
    if java is None:
        raise ValueError("java/pom.xml has no project version")

    cpp_source = (bindings / "cpp/CMakeLists.txt").read_text(encoding="utf-8")
    cpp_match = re.search(
        r"(?m)^project\(cmux_tui_sdk VERSION ([0-9]+\.[0-9]+\.[0-9]+) ",
        cpp_source,
    )
    if cpp_match is None:
        raise ValueError("cpp/CMakeLists.txt has no cmux_tui_sdk project version")

    zig_source = (bindings / "zig/build.zig").read_text(encoding="utf-8")
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
        "rust-sidebar": str(rust_sidebar),
        "java": java,
        "cpp": cpp_match.group(1),
        "zig": zig_match.group(1),
    }


def read_sidebar_client_version(bindings: Path = BINDINGS) -> str:
    manifest = tomllib.loads(
        (bindings / "rust-sidebar/Cargo.toml").read_text(encoding="utf-8")
    )
    dependency = manifest.get("dependencies", {}).get("cmux-client")
    if not isinstance(dependency, dict) or "version" not in dependency:
        raise ValueError(
            "rust-sidebar/Cargo.toml cmux-client dependency has no version"
        )
    version = dependency["version"]
    if not isinstance(version, str):
        raise ValueError(
            "rust-sidebar/Cargo.toml cmux-client dependency version is not a string"
        )
    return version


def main(argv: list[str] | None = None, *, bindings: Path = BINDINGS) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", help="require this X.Y.Z release version")
    arguments = parser.parse_args(argv)
    try:
        versions = read_versions(bindings)
        sidebar_client_version = read_sidebar_client_version(bindings)
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
    if sidebar_client_version != version:
        print(
            "SDK version error: rust-sidebar cmux-client dependency "
            f"must be {version}, found {sidebar_client_version}",
            file=sys.stderr,
        )
        return 1
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
