#!/usr/bin/env python3
"""Sync every SDK's capability descriptor from the canonical catalog.

Writes the same `.cmux-resource-api.json` to all seven high-level SDKs (the
list the resource boundary check reads). `--check` writes nothing and exits 1,
naming each descriptor that differs or is missing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


TUI_ROOT = Path(__file__).resolve().parents[3]
CATALOG = Path("spec") / "resource-operations-v2.json"
DESCRIPTOR = ".cmux-resource-api.json"
# Keep in step with check-resource-api-boundary.py `_sdk_descriptor_classes`.
PACKAGES = ("cpp", "go", "java", "python", "rust", "typescript", "zig")


def descriptor_text(catalog: dict) -> str:
    canonical = json.dumps(
        catalog, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    descriptor = {
        "protocol": catalog["protocol"],
        "catalog_sha256": hashlib.sha256(canonical).hexdigest(),
        "operations": {
            name: {"class": operation["class"]}
            for name, operation in sorted(catalog["operations"].items())
        },
    }
    return json.dumps(descriptor, indent=2, sort_keys=True) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=TUI_ROOT, help="the cmux-tui directory")
    parser.add_argument("--check", action="store_true", help="write nothing; fail on any difference")
    arguments = parser.parse_args(argv)
    root: Path = arguments.root

    missing = [package for package in PACKAGES if not (root / "bindings" / package).is_dir()]
    if missing:
        for package in missing:
            print(f"sync-resource-api: bindings/{package} is missing", file=sys.stderr)
        return 1

    text = descriptor_text(json.loads((root / CATALOG).read_text()))
    targets = [root / "bindings" / package / DESCRIPTOR for package in PACKAGES]
    if arguments.check:
        stale = [path for path in targets if not path.is_file() or path.read_text() != text]
        for path in stale:
            print(
                f"sync-resource-api: {path.relative_to(root).as_posix()} does not match "
                f"{CATALOG.as_posix()}; run bindings/rust/scripts/sync-resource-api.py",
                file=sys.stderr,
            )
        return 1 if stale else 0
    for path in targets:
        path.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
