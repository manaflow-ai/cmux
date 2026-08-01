#!/usr/bin/env python3
"""Reconcile immutable registry artifacts after ambiguous publish failures."""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
from typing import Any, Callable, Optional, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


MATCH = "match"
MISSING = "missing"
USER_AGENT = "cmux-sdk-release-reconciler/1"
STABLE_VERSION = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)


class RegistryError(RuntimeError):
    """Raised when a registry response cannot prove a safe publish decision."""


class RegistryLookupError(RegistryError):
    """Raised when a registry cannot temporarily be queried."""


class ArtifactMismatch(RegistryError):
    """Raised when an immutable registry version contains different bytes."""


class RegistryCancellation(RegistryError):
    """Raised when registry reconciliation is cancelled."""


class ReleaseStateMismatch(RegistryError):
    """Raised when exact bytes are not usable through the registry's stable path."""


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


def _stable_version(value: str) -> Optional[tuple[int, int, int]]:
    match = STABLE_VERSION.fullmatch(value)
    if match is None:
        return None
    return tuple(int(part) for part in match.groups())


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
    except (OSError, http.client.IncompleteRead) as error:
        raise RegistryLookupError(
            f"registry response was interrupted: {url}: {error}"
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
    metadata_url = (
        "https://crates.io/api/v1/crates/"
        f"{quote(package, safe='')}/{quote(version, safe='')}"
    )
    metadata = _json(metadata_url)
    if metadata is None:
        return MISSING
    version_metadata = metadata.get("version")
    if not isinstance(version_metadata, dict):
        raise RegistryError(
            f"crates.io metadata has no version object for {package}@{version}"
        )
    yanked = version_metadata.get("yanked")
    if not isinstance(yanked, bool):
        raise RegistryError(
            f"crates.io metadata has no yanked state for {package}@{version}"
        )
    if yanked:
        raise ReleaseStateMismatch(
            f"crates.io release {package}@{version} is yanked"
        )

    url = (
        "https://crates.io/api/v1/crates/"
        f"{quote(package, safe='')}/{quote(version, safe='')}/download"
    )
    published = _request(url, "application/octet-stream")
    if published is None:
        raise RegistryError(
            f"crates.io metadata exists but its archive is missing for {package}@{version}"
        )
    local = _digest(artifact, "sha256")
    remote = hashlib.sha256(published).hexdigest()
    if local != remote:
        raise ArtifactMismatch(
            f"crates.io already has different bytes for {package}@{version}: "
            f"local sha256={local}, remote sha256={remote}"
        )
    return MATCH


def _npm_status(package: str, version: str, artifact: Path) -> str:
    url = "https://registry.npmjs.org/" f"{quote(package, safe='')}"
    metadata = _json(url)
    if metadata is None:
        return MISSING
    versions = metadata.get("versions")
    if not isinstance(versions, dict):
        raise RegistryError(f"npm metadata has no versions object for {package}")
    candidate = _stable_version(version)
    if candidate is None:
        raise RegistryError(f"npm release version must match X.Y.Z: {version!r}")
    dist_tags = metadata.get("dist-tags")
    if not isinstance(dist_tags, dict):
        raise RegistryError(f"npm metadata has no dist-tags object for {package}")
    release = versions.get(version)
    if release is None:
        newer_or_equal: list[tuple[tuple[int, int, int], str]] = []
        for existing in versions:
            if not isinstance(existing, str):
                continue
            parsed = _stable_version(existing)
            if parsed is not None and parsed >= candidate:
                newer_or_equal.append((parsed, existing))
        if newer_or_equal:
            newest = max(newer_or_equal)[1]
            raise ReleaseStateMismatch(
                f"npm already contains stable version {newest!r}, "
                f"which is not older than requested {version!r}"
            )
        latest = dist_tags.get("latest")
        if latest is not None:
            if not isinstance(latest, str):
                raise RegistryError(
                    f"npm dist-tag latest is malformed for {package}: {latest!r}"
                )
            latest_version = _stable_version(latest)
            if latest_version is None:
                raise ReleaseStateMismatch(
                    f"npm dist-tag latest is not a stable X.Y.Z version: {latest!r}"
                )
            if latest_version >= candidate:
                raise ReleaseStateMismatch(
                    f"npm dist-tag latest points to {latest!r}, which is not older "
                    f"than requested {version!r}"
                )
        return MISSING
    if not isinstance(release, dict):
        raise RegistryError(f"npm metadata is malformed for {package}@{version}")
    dist = release.get("dist")
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
    else:
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
    latest = dist_tags.get("latest")
    if latest != version:
        raise ReleaseStateMismatch(
            f"npm dist-tag latest points to {latest!r}, expected {version!r}"
        )
    return MATCH


def _pypi_status(
    package: str,
    version: str,
    artifact: Path,
    allowed_artifacts: Sequence[Path],
) -> str:
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

    allowed_by_name: dict[str, Path] = {}
    for allowed in allowed_artifacts:
        existing = allowed_by_name.get(allowed.name)
        if existing is not None and existing != allowed:
            raise RegistryError(
                f"multiple allowed PyPI artifacts use filename {allowed.name}"
            )
        allowed_by_name[allowed.name] = allowed
    if artifact.name not in allowed_by_name:
        raise RegistryError(
            f"target PyPI artifact {artifact.name} is absent from the allowed release set"
        )

    published_names: set[str] = set()
    for published in files:
        if not isinstance(published, dict):
            raise RegistryError(
                f"PyPI returned malformed file metadata for {package}=={version}"
            )
        filename = published.get("filename")
        if not isinstance(filename, str):
            raise RegistryError(
                f"PyPI returned a file without a filename for {package}=={version}"
            )
        if filename in published_names:
            raise RegistryError(
                f"PyPI returned duplicate metadata for {package}=={version} file {filename}"
            )
        published_names.add(filename)
        expected = allowed_by_name.get(filename)
        if expected is None:
            raise ArtifactMismatch(
                f"PyPI release {package}=={version} contains unexpected file {filename}"
            )
        if published.get("yanked") is True:
            raise ArtifactMismatch(
                f"PyPI release {package}=={version} contains yanked file {filename}"
            )
        digests = published.get("digests")
        remote = digests.get("sha256") if isinstance(digests, dict) else None
        if not isinstance(remote, str):
            raise RegistryError(
                f"PyPI metadata has no sha256 for {package}=={version} file {filename}"
            )
        local = _digest(expected, "sha256")
        if local != remote:
            raise ArtifactMismatch(
                f"PyPI already has different bytes for {package}=={version} file "
                f"{filename}: local sha256={local}, remote sha256={remote}"
            )
    return MATCH if artifact.name in published_names else MISSING


def registry_status(
    registry: str,
    package: str,
    version: str,
    artifact: Path,
    allowed_artifacts: Optional[Sequence[Path]] = None,
) -> str:
    if not artifact.is_file():
        raise RegistryError(f"local artifact does not exist: {artifact}")
    allowed = tuple(allowed_artifacts or (artifact,))
    for allowed_artifact in allowed:
        if not allowed_artifact.is_file():
            raise RegistryError(
                f"allowed local artifact does not exist: {allowed_artifact}"
            )
    if registry == "pypi":
        return _pypi_status(package, version, artifact, allowed)
    if allowed_artifacts is not None:
        raise RegistryError("--allowed-artifact is supported only for PyPI")
    handlers: dict[str, Callable[[str, str, Path], str]] = {
        "crates": _crates_status,
        "npm": _npm_status,
    }
    return handlers[registry](package, version, artifact)


def wait_for_status(
    registry: str,
    package: str,
    version: str,
    artifact: Path,
    wait_seconds: int,
    *,
    allowed_artifacts: Optional[Sequence[Path]] = None,
    cancel_event: Optional[threading.Event] = None,
    wait_for_match: bool = True,
) -> str:
    cancellation = cancel_event or threading.Event()
    deadline = time.monotonic() + wait_seconds
    last_error: Optional[RegistryError] = None
    while True:
        if cancellation.is_set():
            raise RegistryCancellation("registry reconciliation was cancelled")
        try:
            status = registry_status(
                registry,
                package,
                version,
                artifact,
                allowed_artifacts,
            )
            last_error = None
            if status == MATCH:
                return MATCH
            if not wait_for_match:
                return MISSING
        except RegistryLookupError as error:
            last_error = error
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            if last_error is not None:
                raise last_error
            return MISSING
        if cancellation.wait(min(5, remaining)):
            raise RegistryCancellation("registry reconciliation was cancelled")


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
    parser.add_argument("--allowed-artifact", action="append", type=Path)
    parser.add_argument("--wait-seconds", type=int, default=0)
    parser.add_argument("--require-match", action="store_true")
    parser.add_argument("--write-github-output", action="store_true")
    return parser


def main(
    argv: Optional[Sequence[str]] = None,
    *,
    cancel_event: Optional[threading.Event] = None,
) -> int:
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
            args.wait_seconds,
            allowed_artifacts=args.allowed_artifact,
            cancel_event=cancel_event,
            wait_for_match=args.mode == "check" and args.require_match,
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
            allowed_artifacts=args.allowed_artifact,
            cancel_event=cancel_event,
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


def _run_cli() -> int:
    cancellation = threading.Event()

    def cancel(_signum: int, _frame: object) -> None:
        cancellation.set()
        raise KeyboardInterrupt

    previous_handlers = {
        signum: signal.signal(signum, cancel)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        return main(cancel_event=cancellation)
    except KeyboardInterrupt:
        print("registry reconciliation cancelled", file=sys.stderr)
        return 130
    finally:
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)


if __name__ == "__main__":
    raise SystemExit(_run_cli())
