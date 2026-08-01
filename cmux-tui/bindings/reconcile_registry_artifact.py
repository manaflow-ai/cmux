#!/usr/bin/env python3
"""Reconcile immutable registry artifacts after ambiguous publish failures."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any, Callable, Optional, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


MATCH = "match"
MISSING = "missing"
USER_AGENT = "cmux-sdk-release-reconciler/1"


class RegistryError(RuntimeError):
    """Raised when a registry response cannot prove a safe publish decision."""


class RegistryLookupError(RegistryError):
    """Raised when a registry cannot temporarily be queried."""


class ArtifactMismatch(RegistryError):
    """Raised when an immutable registry version contains different bytes."""


def _digest(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _integrity(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    encoded = base64.b64encode(digest.digest()).decode("ascii")
    return f"{algorithm}-{encoded}"


def _request(url: str, accept: str) -> Optional[bytes]:
    request = Request(
        url,
        headers={"Accept": accept, "User-Agent": USER_AGENT},
    )
    try:
        with urlopen(request, timeout=20) as response:
            return response.read()
    except HTTPError as error:
        if error.code == 404:
            return None
        raise RegistryLookupError(
            f"registry request failed with HTTP {error.code}: {url}"
        ) from error
    except URLError as error:
        raise RegistryLookupError(
            f"registry request failed: {url}: {error.reason}"
        ) from error


def _json(url: str) -> Optional[dict[str, Any]]:
    payload = _request(url, "application/json")
    if payload is None:
        return None
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RegistryError(f"registry returned invalid JSON: {url}") from error
    if not isinstance(value, dict):
        raise RegistryError(f"registry returned a non-object JSON response: {url}")
    return value


def _crates_status(package: str, version: str, artifact: Path) -> str:
    url = (
        "https://crates.io/api/v1/crates/"
        f"{quote(package, safe='')}/{quote(version, safe='')}/download"
    )
    published = _request(url, "application/octet-stream")
    if published is None:
        return MISSING
    local = _digest(artifact, "sha256")
    remote = hashlib.sha256(published).hexdigest()
    if local != remote:
        raise ArtifactMismatch(
            f"crates.io already has different bytes for {package}@{version}: "
            f"local sha256={local}, remote sha256={remote}"
        )
    return MATCH


def _npm_status(package: str, version: str, artifact: Path) -> str:
    url = (
        "https://registry.npmjs.org/"
        f"{quote(package, safe='')}/{quote(version, safe='')}"
    )
    metadata = _json(url)
    if metadata is None:
        return MISSING
    dist = metadata.get("dist")
    if not isinstance(dist, dict):
        raise RegistryError(f"npm metadata has no dist object for {package}@{version}")
    integrity = dist.get("integrity")
    if isinstance(integrity, str) and "-" in integrity:
        algorithm = integrity.split("-", 1)[0]
        try:
            local = _integrity(artifact, algorithm)
        except ValueError as error:
            raise RegistryError(
                "npm returned an unsupported integrity algorithm for "
                f"{package}@{version}: "
                f"{algorithm}"
            ) from error
        if local != integrity:
            raise ArtifactMismatch(
                f"npm already has different bytes for {package}@{version}: "
                f"local integrity={local}, remote integrity={integrity}"
            )
        return MATCH
    shasum = dist.get("shasum")
    if not isinstance(shasum, str):
        raise RegistryError(
            f"npm metadata has no usable digest for {package}@{version}"
        )
    local = _digest(artifact, "sha1")
    if local != shasum:
        raise ArtifactMismatch(
            f"npm already has different bytes for {package}@{version}: "
            f"local sha1={local}, remote sha1={shasum}"
        )
    return MATCH


def _pypi_status(package: str, version: str, artifact: Path) -> str:
    url = (
        "https://pypi.org/pypi/"
        f"{quote(package, safe='')}/{quote(version, safe='')}/json"
    )
    metadata = _json(url)
    if metadata is None:
        return MISSING
    files = metadata.get("urls")
    if not isinstance(files, list):
        raise RegistryError(f"PyPI metadata has no file list for {package}=={version}")
    published = next(
        (
            item
            for item in files
            if isinstance(item, dict) and item.get("filename") == artifact.name
        ),
        None,
    )
    if published is None:
        return MISSING
    digests = published.get("digests")
    remote = digests.get("sha256") if isinstance(digests, dict) else None
    if not isinstance(remote, str):
        raise RegistryError(
            f"PyPI metadata has no sha256 for {package}=={version} file {artifact.name}"
        )
    local = _digest(artifact, "sha256")
    if local != remote:
        raise ArtifactMismatch(
            f"PyPI already has different bytes for {package}=={version} file "
            f"{artifact.name}: local sha256={local}, remote sha256={remote}"
        )
    return MATCH


def registry_status(
    registry: str,
    package: str,
    version: str,
    artifact: Path,
) -> str:
    if not artifact.is_file():
        raise RegistryError(f"local artifact does not exist: {artifact}")
    handlers: dict[str, Callable[[str, str, Path], str]] = {
        "crates": _crates_status,
        "npm": _npm_status,
        "pypi": _pypi_status,
    }
    return handlers[registry](package, version, artifact)


def wait_for_status(
    registry: str,
    package: str,
    version: str,
    artifact: Path,
    wait_seconds: int,
) -> str:
    deadline = time.monotonic() + wait_seconds
    last_error: Optional[RegistryError] = None
    while True:
        try:
            status = registry_status(registry, package, version, artifact)
            last_error = None
            if status == MATCH:
                return MATCH
        except RegistryLookupError as error:
            last_error = error
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            if last_error is not None:
                raise last_error
            return MISSING
        time.sleep(min(5, remaining))


def _write_github_output(status: str) -> None:
    output = os.environ.get("GITHUB_OUTPUT")
    if not output:
        raise RegistryError("GITHUB_OUTPUT is required with --write-github-output")
    with Path(output).open("a", encoding="utf-8") as handle:
        handle.write(f"status={status}\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "publish"))
    parser.add_argument("--registry", choices=("crates", "npm", "pypi"), required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--wait-seconds", type=int, default=0)
    parser.add_argument("--require-match", action="store_true")
    parser.add_argument("--write-github-output", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = list(argv if argv is not None else sys.argv[1:])
    if "--" in arguments:
        separator = arguments.index("--")
        command = arguments[separator + 1 :]
        arguments = arguments[:separator]
    else:
        command = []
    args = _parser().parse_args(arguments)
    if args.wait_seconds < 0:
        raise SystemExit("--wait-seconds must be non-negative")
    if args.mode == "publish" and not command:
        raise SystemExit("publish mode requires a command after --")
    if args.mode == "check" and command:
        raise SystemExit("check mode does not accept a command")

    try:
        status = wait_for_status(
            args.registry,
            args.package,
            args.version,
            args.artifact,
            args.wait_seconds if args.mode == "check" else 0,
        )
        if args.write_github_output:
            _write_github_output(status)
        if args.mode == "check":
            print(f"registry artifact status: {status}")
            return 0 if status == MATCH or not args.require_match else 1
        if status == MATCH:
            print(
                "registry already contains the exact local artifact; skipping publish"
            )
            return 0

        result = subprocess.run(command, check=False)
        if result.returncode == 0:
            return 0
        print(
            f"publish command exited {result.returncode}; reconciling registry state",
            file=sys.stderr,
        )
        status = wait_for_status(
            args.registry,
            args.package,
            args.version,
            args.artifact,
            args.wait_seconds,
        )
        if status == MATCH:
            print(
                "registry accepted the exact local artifact; treating publish as successful"
            )
            return 0
        return result.returncode or 1
    except RegistryError as error:
        print(f"registry reconciliation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
