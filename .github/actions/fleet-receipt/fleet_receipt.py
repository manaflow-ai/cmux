#!/usr/bin/env python3
"""Portable CI receipt runner; stdlib only and safe dry-run by default."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "cmux.fleet.receipt/v1"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def command_digest(command: str) -> str:
    return hashlib.sha256(command.encode("utf-8")).hexdigest()


def runner_info() -> dict[str, object]:
    # Deliberately avoid hostname, home paths, and environment values. A receipt
    # can be uploaded by an outside repository without disclosing fleet topology.
    return {
        "os": platform.system().lower(),
        "arch": platform.machine().lower(),
        "cpu_count": os.cpu_count() or 1,
        "provider": os.environ.get("FLEET_PROVIDER", "local"),
        "pool": os.environ.get("FLEET_POOL", "default"),
        "runner": os.environ.get("RUNNER_ENVIRONMENT", "unknown"),
    }


def write_receipt(path: Path, receipt: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temp.replace(path)


def execute(command: str, timeout: float) -> tuple[int, str | None]:
    """Run in a process group so timeout cleanup reaches grandchildren."""
    process = subprocess.Popen(command, shell=True, start_new_session=True)
    try:
        process.wait(timeout=timeout)
        return process.returncode, None
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return 124, "timeout"


def run(args: argparse.Namespace) -> int:
    if not args.command.strip():
        raise SystemExit("command must not be empty")
    if args.timeout_seconds <= 0:
        raise SystemExit("timeout-seconds must be positive")
    started = time.monotonic()
    started_at = utc_now()
    run_id = os.environ.get("GITHUB_RUN_ID") or os.environ.get("CI_JOB_ID") or f"local-{uuid.uuid4().hex[:12]}"
    receipt: dict[str, object] = {
        "schema": SCHEMA,
        "run_id": run_id,
        "mode": "execute" if args.execute else "dry-run",
        "command_sha256": command_digest(args.command),
        "command_argv_count": len(args.command.split()),
        "started_at": started_at,
        "finished_at": None,
        "duration_ms": None,
        "exit_code": None,
        "status": "planned" if not args.execute else "running",
        "runner": runner_info(),
        "git": {
            "sha": os.environ.get("GITHUB_SHA"),
            "ref": os.environ.get("GITHUB_REF_NAME") or os.environ.get("GITHUB_REF"),
        },
        "timeout_seconds": args.timeout_seconds,
    }
    if args.execute:
        exit_code, failure = execute(args.command, args.timeout_seconds)
        receipt["exit_code"] = exit_code
        receipt["status"] = "passed" if exit_code == 0 else "timed_out" if failure == "timeout" else "failed"
        if failure:
            receipt["failure"] = failure
    elapsed = round((time.monotonic() - started) * 1000)
    receipt["finished_at"] = utc_now()
    receipt["duration_ms"] = elapsed
    write_receipt(Path(args.output), receipt)
    print(json.dumps({"status": receipt["status"], "duration_ms": elapsed, "receipt": args.output}, sort_keys=True))
    if args.execute and receipt["exit_code"] != 0:
        return int(receipt["exit_code"])
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--command", dest="command", help="shell command to plan or run")
    p.add_argument("--shell", dest="shell_command", help=argparse.SUPPRESS)
    p.add_argument("--execute", action="store_true", help="run the command; default only writes a plan")
    p.add_argument("--timeout-seconds", type=float, default=900)
    p.add_argument("--output", default=".cmux/fleet-receipt.json")
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    args.command = args.command or args.shell_command or ""
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
