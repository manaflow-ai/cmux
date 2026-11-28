#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Store the upstream license files of crates that ship none, for review.

  fetch_reviewed_text.py --cache DIR NAME VERSION [NAME VERSION ...]

DIR is a fetch_crates.py cache. For each crate the tool reads the commit and
path that the .crate's .cargo_vcs_info.json records and the manifest's GitHub
`repository`, then looks for LICENSE files at the crate's path in that commit
and in each parent directory up to the repository root; the nearest directory
with any wins. The files are stored verbatim under
texts/<owner>-<repo>-<sha12>/ and recorded in reviewed.json license_texts
with their source URL and sha256. A crate without that metadata or without
any file is an error: the license review then decides by hand (REVIEW.md).
Run REVIEW.md generation afterwards (review_list.py).
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import tomllib
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
NAMES = [
    "LICENSE", "LICENSE-MIT", "LICENSE-APACHE", "LICENSE-ZLIB", "LICENSE.md", "LICENSE.txt",
    "LICENSE-MIT.md", "LICENSE-APACHE.md", "LICENSE-ZLIB.md", "LICENSE-MIT.txt", "LICENSE-APACHE.txt",
    "LICENSE-BSD", "COPYING", "LICENCE", "UNLICENSE", "NOTICE",
]
REGISTRY = Path("registry/src/index.crates.io-notices")


def exists(url: str) -> bool:
    try:
        urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=30)
        return True
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


def upstream_files(crate_dir: Path) -> tuple[str, str, list[str]]:
    vcs = json.loads((crate_dir / ".cargo_vcs_info.json").read_text(encoding="utf-8"))
    sha, sub = vcs["git"]["sha1"], vcs.get("path_in_vcs", "")
    repository = tomllib.loads((crate_dir / "Cargo.toml").read_text(encoding="utf-8"))["package"]["repository"]
    match = re.match(r"https://github\.com/([^/]+/[^/]+?)(\.git)?/?$", repository)
    if not match:
        raise SystemExit(f"{crate_dir.name}: repository {repository!r} is not a GitHub repository; review by hand")
    owner_repo = match.group(1)
    parts = [p for p in sub.split("/") if p]
    for depth in range(len(parts), -1, -1):
        prefix = "/".join(parts[:depth])
        found = [f"{prefix}/{n}" if prefix else n for n in NAMES
                 if exists(f"https://raw.githubusercontent.com/{owner_repo}/{sha}/{prefix + '/' if prefix else ''}{n}")]
        if found:
            return owner_repo, sha, found
    raise SystemExit(f"{crate_dir.name}: no license file in {owner_repo} at {sha}; review by hand")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("crates", nargs="+", help="NAME VERSION pairs")
    args = parser.parse_args(argv)
    if len(args.crates) % 2:
        parser.error("crates come as NAME VERSION pairs")
    reviewed_path = HERE / "reviewed.json"
    reviewed = json.loads(reviewed_path.read_text(encoding="utf-8"))
    texts = reviewed.setdefault("license_texts", {})
    for name, version in zip(args.crates[::2], args.crates[1::2]):
        owner_repo, sha, files = upstream_files(args.cache / REGISTRY / f"{name}-{version}")
        entries = []
        for path in files:
            url = f"https://raw.githubusercontent.com/{owner_repo}/{sha}/{path}"
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            rel = Path("texts") / f"{owner_repo.replace('/', '-')}-{sha[:12]}" / Path(path).name
            dest = HERE / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.exists() and dest.read_bytes() != data:
                raise SystemExit(f"{dest}: exists with other content")
            dest.write_bytes(data)
            entries.append({"file": rel.as_posix(), "source": url, "sha256": hashlib.sha256(data).hexdigest()})
        names = ", ".join(Path(p).name for p in files)
        texts[f"{name} {version}"] = {
            "reason": f"the .crate ships no license file; the text is the repository's {names} at the commit that .cargo_vcs_info.json records for this release",
            "files": entries,
        }
        print(f"{name} {version}: {owner_repo}@{sha[:12]} {names}")
    reviewed["license_texts"] = dict(sorted(texts.items()))
    reviewed_path.write_text(json.dumps(reviewed, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
