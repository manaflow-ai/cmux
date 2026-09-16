#!/usr/bin/env python3
"""Compare Swift and Rust CLI processes in isolated fixture cases.

The report is smoke evidence for the listed cases. It is not a claim of full
family parity and cannot authorize the Swift cutover by itself.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_CASES = Path(__file__).with_suffix(".json")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_digest(path: Path, name: str) -> str:
    """Hash JSON state canonically when Swift dictionary order is unstable."""
    data = path.read_bytes()
    if name.endswith(".json"):
        try:
            value = json.loads(data)
            data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        except (ValueError, UnicodeDecodeError):
            pass
    return hashlib.sha256(data).hexdigest()


def snapshot(root: Path) -> dict:
    result = {}
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = {"symlink": os.readlink(path)}
        elif path.is_file():
            result[name] = {
                "sha256": file_digest(path, name),
                "size": path.stat().st_size,
                "mode": path.stat().st_mode & 0o777,
            }
    return result


def changes(before: dict, after: dict) -> dict:
    return {
        name: {"before": before.get(name), "after": after.get(name)}
        for name in sorted(before.keys() | after.keys())
        if before.get(name) != after.get(name)
    }


def canonical_request(line: bytes):
    try:
        value = json.loads(line)
    except (ValueError, UnicodeDecodeError):
        return {"v1": line.decode("utf-8", errors="replace")}
    if isinstance(value, dict) and "method" in value:
        return {key: item for key, item in value.items() if key != "id"}
    return value


class FixtureServer:
    def __init__(self, path: Path, replies: dict):
        self.path = path
        self.replies = replies
        self.requests = []
        self.reply_offsets = {}
        self.raw_requests_base64 = []
        self.stopping = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        self.listener.listen(8)
        self.listener.settimeout(0.1)
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopping.set()
        self.thread.join(timeout=2)
        self.listener.close()
        self.path.unlink(missing_ok=True)

    def serve(self):
        while not self.stopping.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with connection:
                connection.settimeout(0.1)
                buffered = b""
                while not self.stopping.is_set():
                    try:
                        chunk = connection.recv(65536)
                    except socket.timeout:
                        continue
                    except OSError:
                        break
                    if not chunk:
                        break
                    buffered += chunk
                    while b"\n" in buffered:
                        line, buffered = buffered.split(b"\n", 1)
                        if not line:
                            continue
                        self.raw_requests_base64.append(
                            base64.b64encode(line + b"\n").decode()
                        )
                        self.requests.append(canonical_request(line))
                        try:
                            connection.sendall(self.reply(line))
                        except OSError:
                            return

    def reply(self, line: bytes) -> bytes:
        try:
            request = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            command = line.decode("utf-8", errors="replace")
            reply = self.replies.get("v1", {}).get(
                command, self.replies.get("v1_default", "OK")
            )
            return (reply + "\n").encode()
        method = request.get("method")
        result = self.replies.get("v2", {}).get(method, {})
        if isinstance(result, dict) and "__sequence__" in result:
            sequence = result["__sequence__"]
            offset = self.reply_offsets.get(method, 0)
            self.reply_offsets[method] = offset + 1
            if not sequence:
                raise ValueError(f"empty fixture response sequence: {method}")
            result = sequence[min(offset, len(sequence) - 1)]
        if isinstance(result, dict) and "__error__" in result:
            payload = {
                "id": request.get("id"),
                "ok": False,
                "error": result["__error__"],
            }
        else:
            payload = {"id": request.get("id"), "ok": True, "result": result}
        return (json.dumps(payload, separators=(",", ":")) + "\n").encode()


def run_case(binary: Path, case: dict, root: Path) -> dict:
    if root.exists():
        shutil.rmtree(root)
    root.mkdir()
    home = root / "home"
    home.mkdir()
    (home / ".cmuxterm").mkdir()
    bin_dir = root / "bin"
    bin_dir.mkdir()
    broker = bin_dir / "coderouter-fixture"
    broker.write_text(
        "#!/bin/sh\n"
        "printf 'coderouter fixture:'\n"
        "for arg do printf '<%s>' \"$arg\"; done\n"
        "printf '\\n'\n"
    )
    broker.chmod(0o755)
    # The supported Swift path resolves coderouter/cr on PATH. Keep the old
    # override too so this corpus can compare pre-migration oracle binaries.
    (bin_dir / "coderouter").symlink_to(broker.name)
    (bin_dir / "cr").symlink_to(broker.name)
    environment = {
        "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "CFFIXED_USER_HOME": str(home),
        "CODEX_HOME": str(home / ".codex"),
        "CLAUDE_CONFIG_DIR": str(home / ".claude"),
        "CMUX_AGENT_HOOK_STATE_DIR": str(home / ".cmuxterm"),
        "CMUX_CODEROUTER_PATH": str(broker),
        "CMUX_CODEROUTER_DISABLE_BUNDLED": "1",
        "CMUX_CLI_SENTRY_DISABLED": "1",
        "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC": "1",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "TERM": "dumb",
        "NO_COLOR": "1",
    }
    environment.update(case.get("environment", {}))
    for name, contents in case.get("executables", {}).items():
        path = bin_dir / name
        if path.parent != bin_dir or not name or name in {"coderouter", "cr", "coderouter-fixture"}:
            raise ValueError(f"invalid fixture executable name: {name}")
        path.write_text(contents)
        path.chmod(0o755)
    for name, contents in case.get("files", {}).items():
        path = home / name
        if not path.resolve().is_relative_to(home.resolve()):
            raise ValueError(f"fixture path is outside HOME: {name}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
    socket_path = root / "control.sock"
    argv = [str(binary)]
    if case.get("socket_env"):
        environment[case.get("socket_env_name", "CMUX_SOCKET_PATH")] = str(socket_path)
    elif case.get("socket_marker"):
        marker = home / ".local/state/cmux/last-socket-path"
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(f"{socket_path}\n")
    elif case.get("socket", True):
        argv += ["--socket", str(socket_path)]
    if case.get("socket", True) and not case.get("socket_env") and not case.get("socket_marker"):
        if not case.get("omit_password"):
            argv += ["--password", case.get("password", "fixture-password")]
    argv += case["argv"]
    before = snapshot(home)
    started = time.monotonic()
    with FixtureServer(socket_path, case.get("replies", {})) as server:
        try:
            completed = subprocess.run(
                argv,
                input=case.get("stdin", "").encode(),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                cwd=root,
                timeout=case.get("timeout", 5),
                check=False,
            )
            status, stdout, stderr, timed_out = (
                completed.returncode,
                completed.stdout,
                completed.stderr,
                False,
            )
        except subprocess.TimeoutExpired as error:
            status, stdout, stderr, timed_out = (
                None,
                error.stdout or b"",
                error.stderr or b"",
                True,
            )
    return {
        "exit_code": status,
        "timed_out": timed_out,
        "stdout_base64": base64.b64encode(stdout).decode(),
        "stderr_base64": base64.b64encode(stderr).decode(),
        "stdout": stdout.decode("utf-8", errors="replace"),
        "stderr": stderr.decode("utf-8", errors="replace"),
        "requests": server.requests,
        "raw_requests_base64": server.raw_requests_base64,
        "file_changes": changes(before, snapshot(home)),
        "duration_seconds": round(time.monotonic() - started, 3),
    }


def differences(swift: dict, rust: dict) -> list[str]:
    fields = (
        "exit_code",
        "timed_out",
        "stdout_base64",
        "stderr_base64",
        "requests",
        "file_changes",
    )
    return [field for field in fields if swift[field] != rust[field]]


def oracle_failures(case: dict, result: dict) -> list[str]:
    """Keep two identical failures from being mistaken for positive parity."""
    errors = []
    if "expected_exit" in case and result["exit_code"] != case["expected_exit"]:
        errors.append(f"exit {result['exit_code']} != {case['expected_exit']}")
    methods = {request.get("method") for request in result["requests"] if isinstance(request, dict)}
    for method in case.get("expected_methods", []):
        if method not in methods:
            errors.append(f"expected request absent: {method}")
    if case.get("socket") is False and result["requests"]:
        errors.append("no-socket fixture made a socket request")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True, type=Path)
    parser.add_argument("--rust", required=True, type=Path)
    parser.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--family", action="append")
    parser.add_argument("--case", action="append", help="select exact case id (repeatable)")
    parser.add_argument("--list", action="store_true", help="print selected cases without running")
    args = parser.parse_args()
    cases = json.loads(args.cases.read_text())["cases"]
    if args.family:
        cases = [case for case in cases if case["family"] in args.family]
    if args.case:
        cases = [case for case in cases if case["id"] in args.case]
    if not cases:
        parser.error("no cases selected")
    if args.list:
        for case in cases:
            print(f"{case['id']}\t{case['family']}\t{' '.join(case['argv'])}")
        return 0
    report = {
        "schema": 1,
        "scope": "smoke",
        "limitations": [
            "Passing listed fixtures does not establish parity for unlisted command paths.",
            "PTY interactivity, signals, streaming reconnects, app lifecycle, and real relay authorization need separate tests.",
            "RPC requests are compared semantically with request IDs removed.",
        ],
        "fixtures_sha256": digest(args.cases),
        "source_sha256": digest(ROOT / "CLI/cmux.swift"),
        "swift_binary": str(args.swift.resolve()),
        "swift_binary_sha256": digest(args.swift),
        "rust_binary": str(args.rust.resolve()),
        "rust_binary_sha256": digest(args.rust),
        "cases": [],
    }
    with tempfile.TemporaryDirectory(prefix="cmux-conformance-", dir="/tmp") as temporary:
        root = Path(temporary) / "run"
        for case in cases:
            swift_result = run_case(args.swift.resolve(), case, root)
            rust_result = run_case(args.rust.resolve(), case, root)
            delta = differences(swift_result, rust_result)
            oracle_errors = oracle_failures(case, swift_result)
            passed = not delta and not swift_result["timed_out"] and not oracle_errors
            report["cases"].append(
                {
                    "id": case["id"],
                    "family": case["family"],
                    "argv": case["argv"],
                    "passed": passed,
                    "differences": delta,
                    "oracle_errors": oracle_errors,
                    "swift": swift_result,
                    "rust": rust_result,
                }
            )
            print(
                f"{'PASS' if passed else 'FAIL'} {case['id']}: "
                f"{', '.join(delta + oracle_errors) or 'equal'}",
                flush=True,
            )
    report["all_passed"] = all(case["passed"] for case in report["cases"])
    report["passed_count"] = sum(case["passed"] for case in report["cases"])
    report["case_count"] = len(report["cases"])
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"{report['passed_count']}/{report['case_count']} cases passed; "
        f"report: {args.report}"
    )
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
