#!/usr/bin/env python3
"""Verify that a downloaded Go module matches an exact Git source tree."""

from __future__ import annotations

import argparse
import hashlib
import io
import re
import stat
import subprocess
import sys
import tarfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


class VerificationError(RuntimeError):
    """Raised when public module bytes cannot be bound to the release source."""


@dataclass(frozen=True)
class Fingerprint:
    size: int
    sha256: str


Manifest = dict[str, Fingerprint]


def _fingerprint_bytes(contents: bytes) -> Fingerprint:
    return Fingerprint(
        size=len(contents),
        sha256=hashlib.sha256(contents).hexdigest(),
    )


def _fingerprint_path(path: Path) -> Fingerprint:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return Fingerprint(size=size, sha256=digest.hexdigest())


def _git(
    repository: Path,
    *arguments: str,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repository,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        raise VerificationError(
            f"git {' '.join(arguments)} failed: {message or result.returncode}"
        )
    return result


def _validated_subdir(value: str) -> str:
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or not path.parts
        or any(part in ("", ".", "..") for part in path.parts)
    ):
        raise VerificationError(
            f"module subdirectory must be a normalized relative path: {value!r}"
        )
    return path.as_posix()


def _go_version(contents: bytes) -> tuple[int, int]:
    match = re.search(rb"(?m)^go[ \t]+([0-9]+)\.([0-9]+)(?:\.[0-9]+)?[ \t]*$", contents)
    if match is None:
        return (0, 0)
    return (int(match.group(1)), int(match.group(2)))


def _is_vendored_package(name: str, go_version: tuple[int, int]) -> bool:
    if go_version >= (1, 24) and name == "vendor/modules.txt":
        return True
    if name.startswith("vendor/"):
        start = len("vendor/")
    else:
        marker = "/vendor/"
        marker_index = name.find(marker)
        if marker_index < 0:
            return False
        if go_version >= (1, 24):
            start = marker_index + len(marker)
        else:
            start = len(marker)
    return "/" in name[start:]


def _module_files(files: Mapping[str, bytes]) -> dict[str, bytes]:
    nested_modules = {
        PurePosixPath(name).parent.as_posix()
        for name in files
        if PurePosixPath(name).name.lower() == "go.mod"
        and PurePosixPath(name).parent != PurePosixPath(".")
    }
    go_version = _go_version(files.get("go.mod", b""))
    included: dict[str, bytes] = {}
    for name, contents in files.items():
        if name == ".hg_archival.txt" or _is_vendored_package(name, go_version):
            continue
        if any(
            name == nested or name.startswith(f"{nested}/") for nested in nested_modules
        ):
            continue
        included[name] = contents
    return included


def source_manifest(
    repository: Path,
    commit: str,
    module_subdir: str,
) -> Manifest:
    repository = repository.resolve()
    if not repository.is_dir():
        raise VerificationError(f"repository is not a directory: {repository}")
    normalized_subdir = _validated_subdir(module_subdir)
    archive = _git(
        repository,
        "-c",
        "core.autocrlf=input",
        "-c",
        "core.eol=lf",
        "archive",
        "--format=tar",
        commit,
        "--",
        normalized_subdir,
    ).stdout
    prefix = f"{normalized_subdir}/"
    source_files: dict[str, bytes] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as contents:
            for member in contents.getmembers():
                if member.isdir() or not member.isfile():
                    continue
                if not member.name.startswith(prefix):
                    raise VerificationError(
                        f"git archive escaped module subdirectory: {member.name!r}"
                    )
                relative = member.name[len(prefix) :]
                if not relative:
                    continue
                handle = contents.extractfile(member)
                if handle is None:
                    raise VerificationError(
                        f"cannot read archived source file: {member.name!r}"
                    )
                source_files[relative] = handle.read()
    except tarfile.TarError as error:
        raise VerificationError(f"cannot read git source archive: {error}") from error

    if not source_files:
        raise VerificationError(
            f"release commit contains no files under {normalized_subdir}"
        )
    if "LICENSE" not in source_files:
        license_blob = _git(
            repository,
            "show",
            f"{commit}:LICENSE",
            check=False,
        )
        if license_blob.returncode == 0:
            source_files["LICENSE"] = license_blob.stdout

    return {
        name: _fingerprint_bytes(contents)
        for name, contents in _module_files(source_files).items()
    }


def directory_manifest(root: Path) -> Manifest:
    root = root.resolve()
    if not root.is_dir():
        raise VerificationError(f"downloaded module is not a directory: {root}")
    manifest: Manifest = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise VerificationError(
                f"downloaded module contains a non-regular path: {relative}"
            )
        manifest[relative] = _fingerprint_path(path)
    if not manifest:
        raise VerificationError("downloaded module contains no files")
    return manifest


def tree_digest(manifest: Mapping[str, Fingerprint]) -> str:
    digest = hashlib.sha256()
    for name in sorted(manifest):
        fingerprint = manifest[name]
        encoded_name = name.encode("utf-8")
        digest.update(len(encoded_name).to_bytes(8, "big"))
        digest.update(encoded_name)
        digest.update(fingerprint.size.to_bytes(8, "big"))
        digest.update(bytes.fromhex(fingerprint.sha256))
    return digest.hexdigest()


def _paths(names: Sequence[str]) -> str:
    shown = list(names[:5])
    suffix = "" if len(names) <= len(shown) else f" (+{len(names) - len(shown)} more)"
    return ", ".join(shown) + suffix


def compare_manifests(expected: Manifest, downloaded: Manifest) -> str:
    expected_names = set(expected)
    downloaded_names = set(downloaded)
    missing = sorted(expected_names - downloaded_names)
    unexpected = sorted(downloaded_names - expected_names)
    changed = sorted(
        name
        for name in expected_names & downloaded_names
        if expected[name] != downloaded[name]
    )
    if missing or unexpected or changed:
        details = []
        if missing:
            details.append(f"missing: {_paths(missing)}")
        if unexpected:
            details.append(f"unexpected: {_paths(unexpected)}")
        if changed:
            details.append(f"changed: {_paths(changed)}")
        raise VerificationError(
            "public Go module does not match the release commit "
            f"(expected {tree_digest(expected)}, downloaded "
            f"{tree_digest(downloaded)}; {'; '.join(details)})"
        )
    return tree_digest(expected)


def verify(
    repository: Path,
    commit: str,
    module_subdir: str,
    downloaded_root: Path,
) -> tuple[str, int]:
    expected = source_manifest(repository, commit, module_subdir)
    downloaded = directory_manifest(downloaded_root)
    return compare_manifests(expected, downloaded), len(expected)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--module-subdir", required=True)
    parser.add_argument("--downloaded-root", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        digest, file_count = verify(
            args.repository,
            args.commit,
            args.module_subdir,
            args.downloaded_root,
        )
    except VerificationError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(
        f"Verified {file_count} public Go module files against release source "
        f"tree {digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
