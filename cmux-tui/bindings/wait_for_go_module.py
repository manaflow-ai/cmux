#!/usr/bin/env python3
"""Wait for a versioned Go module to reach the public proxy and checksum DB."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Sequence
from typing import Any, Optional


class GoModuleError(RuntimeError):
    """Raised when a public Go module cannot be verified safely."""


class GoModuleUnavailable(GoModuleError):
    """Raised when a module remains unavailable through the retry deadline."""


class GoModuleCancellation(GoModuleError):
    """Raised when public module verification is cancelled."""


Runner = Callable[..., subprocess.CompletedProcess[str]]


def _download(
    module: str,
    version: str,
    runner: Runner,
) -> tuple[Optional[dict[str, Any]], str]:
    try:
        result = runner(
            ["go", "mod", "download", "-json", f"{module}@{version}"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise GoModuleError(f"could not run go mod download: {error}") from error

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        return None, detail or f"go mod download exited {result.returncode}"
    try:
        metadata = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GoModuleError("go mod download returned invalid JSON") from error
    if not isinstance(metadata, dict):
        raise GoModuleError("go mod download returned non-object JSON")
    download_error = metadata.get("Error")
    if download_error is not None:
        return None, str(download_error)
    if metadata.get("Path") != module or metadata.get("Version") != version:
        raise GoModuleError(
            "go mod download returned an unexpected module: "
            f"{metadata.get('Path')}@{metadata.get('Version')}"
        )
    return metadata, ""


def wait_for_module(
    module: str,
    version: str,
    *,
    wait_seconds: int,
    retry_seconds: int,
    runner: Runner = subprocess.run,
    clock: Callable[[], float] = time.monotonic,
    cancel_event: Optional[threading.Event] = None,
) -> dict[str, Any]:
    if not module or not version:
        raise GoModuleError("module and version must be non-empty")
    if wait_seconds < 0:
        raise GoModuleError("wait seconds must be non-negative")
    if retry_seconds <= 0:
        raise GoModuleError("retry seconds must be positive")

    cancellation = cancel_event or threading.Event()
    deadline = clock() + wait_seconds
    last_error = "module is unavailable"
    while True:
        if cancellation.is_set():
            raise GoModuleCancellation("Go module verification was cancelled")
        metadata, error = _download(module, version, runner)
        if metadata is not None:
            return metadata
        last_error = error
        remaining = deadline - clock()
        if remaining <= 0:
            raise GoModuleUnavailable(
                f"{module}@{version} did not reach the public Go module path: "
                f"{last_error}"
            )
        if cancellation.wait(min(retry_seconds, remaining)):
            raise GoModuleCancellation("Go module verification was cancelled")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--wait-seconds", type=int, required=True)
    parser.add_argument("--retry-seconds", type=int, default=30)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        metadata = wait_for_module(
            args.module,
            args.version,
            wait_seconds=args.wait_seconds,
            retry_seconds=args.retry_seconds,
        )
    except GoModuleError as error:
        print(f"public Go module verification failed: {error}", file=sys.stderr)
        return 1
    print(
        "public Go module available: "
        f"{metadata['Path']}@{metadata['Version']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
