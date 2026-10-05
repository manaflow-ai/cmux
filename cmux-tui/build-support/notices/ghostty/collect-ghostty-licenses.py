#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Collect license material for the exact Ghostty library dependency cache.

Shared by manaflow-ai/cmux (cmux-next app) and manaflow-ai/cmux-browser, which
vendors cmux-tui/build-support at its cmux-tui pin. Moved from cmux-browser
scripts/collect-ghostty-licenses.py at cc93624d (G1, PR 575) with two changes:
the pinned texts live beside this file (pinned-licenses/), and the caller names
its release source archive with --release-source-offer (the last line of a
generated source offer) instead of importing cmux-browser's release identity.

Package layouts: Zig 0.16 fetches packages into <ghostty source>/zig-pkg/;
older Zig keeps them only in <zig cache>/p/. Both are collected.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sys

LICENSE_NAME = re.compile(
    r"^(license|licence|copying|copyright|notice|authors|ofl|unlicense)"
    r"([._-].*)?$",
    re.IGNORECASE,
)
MAX_LICENSE_BYTES = 2 * 1024 * 1024
# Packages whose fetched tree carries no license file ship upstream texts
# stored in this repository (release-compliance/pinned-licenses), so a build
# is reproducible offline and every text is reviewed in a diff. MANIFEST.json
# names each file's immutable upstream URL and SHA-256; `packages`, when
# present, pins the Zig package directories the texts were reviewed for;
# `source_offer` writes where the Source Code Form is available (MPL-2.0
# section 3.2(a)). The manifest digest is pinned here too, so a text change
# also changes this script, which keys the Ghostty helper caches.
PINNED_LICENSES = Path(__file__).resolve().parent / "pinned-licenses"
PINNED_MANIFEST_SHA256 = (
    "e82f07f18c56f64446b4b730fa89bb561d878c70aad5bff9666c26375a6a092e"
)


def load_known_licenses() -> dict[str, dict]:
    manifest_path = PINNED_LICENSES / "MANIFEST.json"
    content = manifest_path.read_bytes()
    actual = hashlib.sha256(content).hexdigest()
    if actual != PINNED_MANIFEST_SHA256:
        raise ValueError(
            f"pinned license manifest digest changed: {actual} "
            f"(expected {PINNED_MANIFEST_SHA256})"
        )
    manifest = json.loads(content)
    if manifest.get("schema") != 1:
        raise ValueError("unsupported pinned license manifest schema")
    return manifest["packages"]


# Loaded by main() from the pinned manifest.
KNOWN_LICENSES: dict[str, dict] = {}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def license_files(root: Path) -> list[Path]:
    result: list[Path] = []
    for path in root.rglob("*"):
        if (
            path.is_file()
            and ".git" not in path.parts
            and LICENSE_NAME.match(path.name)
            and path.stat().st_size <= MAX_LICENSE_BYTES
        ):
            result.append(path)
    return sorted(result, key=lambda value: value.relative_to(root).as_posix())


def safe_component(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")
    return cleaned or "package"


# Windows installers unpack the payload below a ~100-character temp prefix,
# so the collected tree must never mirror deep source paths. Destinations are
# `<label>/<source-hash12>-<bounded-basename>`; the SOURCE-MANIFEST.json
# `source` field keeps the full original path for every file.
MAX_DESTINATION_CHARS = 80
MAX_BASENAME_CHARS = 40
PACKAGE_LABEL_CHARS = 16


def bounded_destination(label: str, source_key: str, basename: str) -> Path:
    stem = hashlib.sha256(source_key.encode("utf-8")).hexdigest()[:12]
    name = basename[:MAX_BASENAME_CHARS]
    destination = Path(label) / f"{stem}-{name}"
    if len(destination.as_posix()) > MAX_DESTINATION_CHARS:
        raise ValueError(
            f"license destination exceeds the {MAX_DESTINATION_CHARS}-char "
            f"budget: {destination.as_posix()}"
        )
    return destination


def known_license_for(root: Path) -> tuple[str, list[Path]] | None:
    if (root / "UnicodeData.txt").is_file() and (root / "ReadMe.txt").is_file():
        readme = root / "ReadMe.txt"
        if digest(readme) != (
            "14cafa23788d3a20dd21d6b0cdcb8d6dab520781fcd9ad9392f3b88ea607e633"
        ):
            return None
        return "unicode-16", [readme]
    if (root / "dcimgui.cpp").is_file() and (root / "dcimgui.h").is_file():
        return "dear-bindings", []
    zon = root / "build.zig.zon"
    if zon.is_file():
        value = zon.read_text(encoding="utf-8", errors="replace")
        if ".name = .z2d" in value and "SPDX-License-Identifier: MPL-2.0" in value:
            return "z2d", [zon]
        if ".name = .gobject" in value and (root / "src").is_dir():
            return "zig-gobject", []
        return None
    if is_theme_archive(root):
        return "iterm2-themes", []
    return None


def is_theme_archive(root: Path) -> bool:
    """iTerm2-Color-Schemes' Ghostty themes: only flat theme files."""
    entries = list(root.iterdir())
    if not entries or any(not entry.is_file() for entry in entries):
        return False
    return all(
        entry.read_text(encoding="utf-8", errors="replace").lstrip().startswith(("palette", "background", "foreground", "#"))
        for entry in entries
    )


# A Zig package's stable identity is the dependency name that a
# build.zig.zon gives it. Its directory name (`<name>-<version>-<hash>` or
# `N-V-<hash>` for archives without their own build.zig.zon) and its URL
# path both change with every version, so the notice inventory names each
# package by its dependency name and keeps the directory as its version.
ZON_DEPENDENCY = re.compile(
    r'\.(@"[^"\\]+"|[A-Za-z_][A-Za-z0-9_]*)\s*=\s*\.\{([^{}]*)\}'
)
ZON_HASH = re.compile(r'\.hash\s*=\s*"([^"\\]+)"')
ZON_URL = re.compile(r'\.url\s*=\s*"([^"\\]+)"')
DEPENDENCY_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
ZIG_PKG_DIRECTORY = "zig-pkg"


def strip_zon_comments(text: str) -> str:
    """Drop `//` comments; a `//` inside a string literal (a URL) stays."""
    lines = []
    for line in text.splitlines():
        in_string = False
        escaped = False
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


def zon_declarations(roots: list[Path]) -> dict[str, tuple[str, str]]:
    """Map each declared package hash to its (dependency name, URL).

    When several manifests declare one hash, a declaration in Ghostty's own
    manifests (outside fetched packages) wins, then the smallest (name, URL)
    pair, so the result does not depend on directory walk order.
    """
    found: dict[str, set[tuple[int, str, str]]] = {}
    for root_index, root in enumerate(roots):
        if not root.is_dir():
            continue
        for zon in root.rglob("build.zig.zon"):
            relative = zon.relative_to(root).parts
            if ".git" in relative or not zon.is_file():
                continue
            rank = int(root_index > 0 or relative[0] == ZIG_PKG_DIRECTORY)
            text = strip_zon_comments(zon.read_text(encoding="utf-8", errors="replace"))
            for raw_name, body in ZON_DEPENDENCY.findall(text):
                package_hash = ZON_HASH.search(body)
                if package_hash is None:
                    continue
                name = raw_name[2:-1] if raw_name.startswith('@"') else raw_name
                if DEPENDENCY_NAME.fullmatch(name) is None:
                    continue
                url = ZON_URL.search(body)
                found.setdefault(package_hash[1], set()).add(
                    (rank, name, url[1] if url else "")
                )
    return {
        package_hash: min(names)[1:] for package_hash, names in found.items()
    }


def zig_package_directory(entry: dict[str, object]) -> str | None:
    """The Zig package directory a manifest entry came from, if any."""
    if entry["source_kind"] != "ghostty":
        return str(entry["package"])
    parts = str(entry["source"]).split("/")
    if len(parts) > 2 and parts[0] == ZIG_PKG_DIRECTORY:
        return parts[1]
    return None


def zig_package_index(
    entries: list[dict[str, object]], declarations: dict[str, tuple[str, str]]
) -> dict[str, dict[str, str]]:
    """Dependency name and URL for every Zig package with license files."""
    index: dict[str, dict[str, str]] = {}
    for entry in entries:
        directory = zig_package_directory(entry)
        if directory is None or directory not in declarations:
            continue
        name, url = declarations[directory]
        index[directory] = {"dependency": name, "url": url}
    return index


def pinned_license_texts(name: str) -> list[tuple[bytes, str, str]]:
    """(content, file name, upstream URL) for each pinned text of `name`."""
    texts = []
    for item in KNOWN_LICENSES[name]["files"]:
        relative = PurePosixPath(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"pinned license path is unsafe: {item['path']}")
        content = PINNED_LICENSES.joinpath(*relative.parts).read_bytes()
        if len(content) > MAX_LICENSE_BYTES:
            raise ValueError(f"pinned license is unexpectedly large: {item['path']}")
        actual = hashlib.sha256(content).hexdigest()
        if actual != item["sha256"]:
            raise ValueError(
                f"pinned license digest changed for {item['path']}: {actual} "
                f"(expected {item['sha256']})"
            )
        texts.append((content, str(item["filename"]), str(item["upstream"])))
    return texts


def source_offer(
    name: str, package: str, declaration: tuple[str, str] | None, revision: str,
    release_offer: str,
) -> bytes | None:
    """The source location notice for a known license that requires one."""
    offer = KNOWN_LICENSES[name].get("source_offer")
    if offer is None:
        return None
    archive = declaration[1] if declaration is not None and declaration[1] else None
    lines = [
        f"{offer['name']} is licensed under the {offer['license']}.",
        "",
        "The Source Code Form of the exact version in this build is available at:",
        "",
    ]
    if archive is not None:
        lines.append(
            f"- {archive} (the archive that Ghostty {revision} fetches, "
            f"Zig package {package})"
        )
    # The Ghostty helpers are cached per Ghostty revision, not per release,
    # so the caller names its release assets by their scheme.
    lines.extend(
        [
            f"- {offer['upstream']} (upstream tag {offer['upstream_tag']})",
            f"- {release_offer}",
            "",
        ]
    )
    return "\n".join(lines).encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ghostty-source", type=Path, required=True)
    parser.add_argument("--zig-cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument(
        "--release-source-offer", required=True,
        help="the last line of a generated source offer: where this product's "
        "release publishes its source archive",
    )
    args = parser.parse_args()

    try:
        KNOWN_LICENSES.update(load_known_licenses())
    except (OSError, ValueError, KeyError) as error:
        parser.error(f"pinned license manifest is unusable: {error}")
    source = args.ghostty_source.resolve()
    package_root = (args.zig_cache.resolve() / "p")
    output = args.output.resolve()
    if not (source / "LICENSE").is_file():
        parser.error(f"Ghostty LICENSE is missing: {source / 'LICENSE'}")
    if not package_root.is_dir():
        parser.error(f"Zig package cache is missing: {package_root}")

    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    entries: list[dict[str, object]] = []
    unresolved: list[str] = []
    roots: list[tuple[str, Path]] = [("ghostty-source", source)]
    label_owners: dict[str, str] = {"ghostty-source": "ghostty-source"}
    for package in sorted(package_root.iterdir(), key=lambda value: value.name):
        if not package.is_dir():
            continue
        label = safe_component(package.name)[:PACKAGE_LABEL_CHARS]
        previous = label_owners.get(label)
        if previous is not None:
            print(
                f"Ghostty package label collision: {label!r} for both "
                f"{previous!r} and {package.name!r}",
                file=sys.stderr,
            )
            return 1
        label_owners[label] = package.name
        roots.append((label, package))
    destinations: set[str] = set()
    declarations = zon_declarations([source, package_root])

    def record(
        label: str, package: str, source_key: str, filename: str,
        content: bytes, kind: str,
    ) -> None:
        destination = bounded_destination(label, source_key, filename).as_posix()
        if destination in destinations:
            raise ValueError(f"duplicate license destination: {destination}")
        destinations.add(destination)
        target = output / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        entries.append(
            {
                "bytes": len(content),
                "destination": destination,
                "package": package,
                "sha256": digest(target),
                "source": source_key,
                "source_kind": kind,
            }
        )

    def resolve_unlicensed(label: str, base: Path, package: Path, kind: str) -> None:
        """Pinned upstream texts for a package whose tree has no license file."""
        known_license = known_license_for(package)
        if known_license is None:
            unresolved.append(package.name)
            return
        known_name, extra_files = known_license
        pinned = KNOWN_LICENSES[known_name].get("packages")
        if pinned is not None and package.name not in pinned:
            raise ValueError(
                f"{known_name} license texts are reviewed for {pinned}, not "
                f"{package.name}; review them again and pin {package.name} in "
                "pinned-licenses/MANIFEST.json"
            )
        for path in extra_files:
            record(
                label, base.name, path.relative_to(base).as_posix(), path.name,
                path.read_bytes(), kind,
            )
        for content, filename, url in pinned_license_texts(known_name):
            record(label, package.name, url, filename, content, "verified-upstream-license")
        offer = source_offer(
            known_name, package.name, declarations.get(package.name), args.revision,
            args.release_source_offer,
        )
        if offer is not None:
            record(
                label, package.name, f"source-offer:{package.name}",
                f"{known_name}-SOURCE-OFFER.txt", offer, "generated-source-offer",
            )

    try:
        for label, root in roots:
            files = license_files(root)
            kind = "ghostty" if label == "ghostty-source" else "zig-cache"
            for path in files:
                record(
                    label, root.name, path.relative_to(root).as_posix(), path.name,
                    path.read_bytes(), kind,
                )
            if label == "ghostty-source":
                # Zig 0.16 fetches every package into zig-pkg/; each one
                # needs a license file of its own, like a package-cache root.
                zig_pkg = root / ZIG_PKG_DIRECTORY
                covered = {
                    path.relative_to(zig_pkg).parts[0]
                    for path in files
                    if zig_pkg in path.parents
                }
                if zig_pkg.is_dir():
                    for package in sorted(zig_pkg.iterdir(), key=lambda value: value.name):
                        if package.is_dir() and package.name not in covered:
                            resolve_unlicensed(label, root, package, kind)
            elif not files:
                resolve_unlicensed(label, root, root, kind)
    except (OSError, ValueError) as error:
        print(f"could not collect Ghostty licenses: {error}", file=sys.stderr)
        return 1

    manifest = {
        "schema": 1,
        "ghostty_revision": args.revision,
        "license_files": entries,
        "unresolved_packages": unresolved,
        "zig_packages": zig_package_index(entries, declarations),
    }
    (output / "SOURCE-MANIFEST.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    if unresolved:
        print(
            "Ghostty dependency packages without discoverable license files:\n  "
            + "\n  ".join(unresolved)
            + "\nReview each package's upstream license, pin the text in "
            "cmux-tui/build-support/notices/ghostty/pinned-licenses/MANIFEST.json "
            "(and update PINNED_MANIFEST_SHA256 in this collector), then build again.",
            file=sys.stderr,
        )
        return 1
    if len(entries) < 5:
        print(
            f"expected multiple Ghostty dependency licenses, found {len(entries)}",
            file=sys.stderr,
        )
        return 1
    print(f"collected {len(entries)} Ghostty license files into {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
