#!/usr/bin/env python3
"""Wait for a versioned Go module to reach the public proxy and checksum DB."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
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


class GoModuleAttemptTimeout(GoModuleError):
    """Raised when one download attempt reaches the overall deadline."""


Executor = Callable[..., subprocess.CompletedProcess[str]]
POLL_SECONDS = 0.25
STOP_SECONDS = 5
UNAVAILABLE_DETAIL = (
    "the public proxy or checksum database has not made the module available"
)
TIMEOUT_DETAIL = "the public verification attempt reached its deadline"


def _stop_process(process: subprocess.Popen[str]) -> None:
    try:
        process.terminate()
    except OSError:
        pass
    try:
        process.wait(timeout=STOP_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except OSError:
            pass
        try:
            process.wait(timeout=STOP_SECONDS)
        except subprocess.TimeoutExpired as error:
            raise GoModuleError(
                "could not stop public Go module verification"
            ) from error


def _run_command(
    command: Sequence[str],
    *,
    env: dict[str, str],
    deadline: float,
    clock: Callable[[], float],
    cancel_event: threading.Event,
) -> subprocess.CompletedProcess[str]:
    if cancel_event.is_set():
        raise GoModuleCancellation("Go module verification was cancelled")
    if deadline - clock() <= 0:
        raise GoModuleAttemptTimeout(TIMEOUT_DETAIL)
    with tempfile.TemporaryFile(
        mode="w+", encoding="utf-8", errors="replace"
    ) as stdout_buffer, tempfile.TemporaryFile(
        mode="w+", encoding="utf-8", errors="replace"
    ) as stderr_buffer:
        try:
            process = subprocess.Popen(
                list(command),
                stdout=stdout_buffer,
                stderr=stderr_buffer,
                text=True,
                env=env,
            )
        except OSError as error:
            raise GoModuleError(
                "could not start public Go module verification"
            ) from error

        while True:
            if cancel_event.is_set():
                _stop_process(process)
                raise GoModuleCancellation("Go module verification was cancelled")
            remaining = deadline - clock()
            if remaining <= 0:
                _stop_process(process)
                raise GoModuleAttemptTimeout(TIMEOUT_DETAIL)
            try:
                returncode = process.wait(
                    timeout=min(POLL_SECONDS, remaining)
                )
            except subprocess.TimeoutExpired:
                continue
            stdout_buffer.seek(0)
            stderr_buffer.seek(0)
            return subprocess.CompletedProcess(
                list(command),
                returncode,
                stdout=stdout_buffer.read(),
                stderr=stderr_buffer.read(),
            )


def _public_environment(module_cache: str) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "GOENV": "off",
            "GOFLAGS": "",
            "GOINSECURE": "",
            "GOMODCACHE": module_cache,
            "GONOPROXY": "none",
            "GONOSUMDB": "none",
            "GOPRIVATE": "",
            "GOPROXY": "https://proxy.golang.org",
            "GOSUMDB": "sum.golang.org",
            "GOWORK": "off",
        }
    )
    return environment


def _download(
    module: str,
    version: str,
    executor: Executor,
    *,
    env: dict[str, str],
    deadline: float,
    clock: Callable[[], float],
    cancel_event: threading.Event,
) -> tuple[Optional[dict[str, Any]], str]:
    try:
        result = executor(
            ["go", "mod", "download", "-json", f"{module}@{version}"],
            env=env,
            deadline=deadline,
            clock=clock,
            cancel_event=cancel_event,
        )
    except GoModuleAttemptTimeout:
        return None, TIMEOUT_DETAIL
    except OSError as error:
        raise GoModuleError(
            "could not start public Go module verification"
        ) from error

    if result.returncode != 0:
        return None, UNAVAILABLE_DETAIL
    try:
        metadata = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GoModuleError("go mod download returned invalid JSON") from error
    if not isinstance(metadata, dict):
        raise GoModuleError("go mod download returned non-object JSON")
    download_error = metadata.get("Error")
    if download_error is not None:
        return None, UNAVAILABLE_DETAIL
    if metadata.get("Path") != module or metadata.get("Version") != version:
        raise GoModuleError("go mod download returned an unexpected module identity")
    return metadata, ""


def wait_for_module(
    module: str,
    version: str,
    *,
    wait_seconds: int,
    retry_seconds: int,
    executor: Executor = _run_command,
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
    last_error = UNAVAILABLE_DETAIL
    with tempfile.TemporaryDirectory(prefix="cmux-go-module-") as module_cache:
        environment = _public_environment(module_cache)
        while True:
            if cancellation.is_set():
                raise GoModuleCancellation("Go module verification was cancelled")
            metadata, error = _download(
                module,
                version,
                executor,
                env=environment,
                deadline=deadline,
                clock=clock,
                cancel_event=cancellation,
            )
            if metadata is not None:
                return metadata
            last_error = error
            remaining = deadline - clock()
            if remaining <= 0:
                raise GoModuleUnavailable(
                    f"{module}@{version} is unavailable through the public Go "
                    f"module path: {last_error}; retry after proxy propagation"
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


def main(
    argv: Optional[Sequence[str]] = None,
    *,
    cancel_event: Optional[threading.Event] = None,
) -> int:
    args = _parser().parse_args(argv)
    try:
        metadata = wait_for_module(
            args.module,
            args.version,
            wait_seconds=args.wait_seconds,
            retry_seconds=args.retry_seconds,
            cancel_event=cancel_event,
        )
    except GoModuleCancellation:
        print("public Go module verification cancelled", file=sys.stderr)
        return 130
    except GoModuleError as error:
        print(f"public Go module verification failed: {error}", file=sys.stderr)
        return 1
    print(
        "public Go module available: "
        f"{metadata['Path']}@{metadata['Version']}"
    )
    return 0


def _run_cli() -> int:
    cancellation = threading.Event()

    def cancel(_signum: int, _frame: object) -> None:
        cancellation.set()

    previous_handlers = {
        signum: signal.signal(signum, cancel)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        return main(cancel_event=cancellation)
    except KeyboardInterrupt:
        cancellation.set()
        return 130
    finally:
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)


if __name__ == "__main__":
    raise SystemExit(_run_cli())
