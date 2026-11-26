#!/usr/bin/env python3
"""Sync the Rust binding capability descriptor from the canonical catalog."""

from __future__ import annotations

import json
import hashlib
from pathlib import Path


RUST_ROOT = Path(__file__).resolve().parents[1]
CATALOG = RUST_ROOT.parents[1] / "spec" / "resource-operations-v2.json"
MANIFEST = RUST_ROOT / ".cmux-resource-api.json"


def main() -> None:
    catalog = json.loads(CATALOG.read_text())
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
    MANIFEST.write_text(json.dumps(descriptor, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
