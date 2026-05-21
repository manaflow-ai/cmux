#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path

FATAL_OUTPUT_MARKERS = (
    b"Backtrace took",
    b"Program crashed:",
    b"Press space to interact, D to debug",
)


def terminate_process_group(
    process: subprocess.Popen[bytes],
    process_group_id: int,
    grace_seconds: float,
) -> None:
    try:
        os.killpg(process_group_id, signal.SIGTERM)
    except ProcessLookupError:
        return
    except OSError:
        if process.poll() is None:
            process.terminate()

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            break
        time.sleep(0.2)

    try:
        os.killpg(process_group_id, signal.SIGKILL)
    except ProcessLookupError:
        return
    except OSError:
        if process.poll() is None:
            process.kill()


def reap_process(process: subprocess.Popen[bytes], process_group_id: int, grace_seconds: float) -> int:
    if process.poll() is not None:
        return process.returncode
    try:
        return process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        terminate_process_group(process, process_group_id, grace_seconds)
    try:
        return process.wait(timeout=max(1.0, grace_seconds))
    except subprocess.TimeoutExpired:
        return -signal.SIGKILL


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a command and fail if it stops producing output.")
    parser.add_argument("--idle-timeout-seconds", type=float, required=True)
    parser.add_argument("--termination-grace-seconds", type=float, default=10)
    parser.add_argument("--output", required=True, help="Path to write the combined output stream.")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("missing command", file=sys.stderr)
        return 2

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    last_output = time.monotonic()
    timed_out = False
    fatal_marker: bytes | None = None
    output_tail = b""

    with output_path.open("wb") as output_file:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        assert process.stdout is not None
        try:
            process_group_id = os.getpgid(process.pid)
        except ProcessLookupError:
            process_group_id = process.pid
        stdout_fd = process.stdout.fileno()
        os.set_blocking(stdout_fd, False)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        stdout_registered = True

        def write_chunk(chunk: bytes) -> None:
            nonlocal fatal_marker, last_output, output_tail
            output_file.write(chunk)
            output_file.flush()
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            last_output = time.monotonic()
            searchable = output_tail + chunk
            fatal_marker = next((marker for marker in FATAL_OUTPUT_MARKERS if marker in searchable), None)
            output_tail = searchable[-4096:]

        def read_available_stdout() -> bool:
            nonlocal stdout_registered
            while True:
                try:
                    chunk = os.read(stdout_fd, 8192)
                except BlockingIOError:
                    return True
                except OSError:
                    if stdout_registered:
                        selector.unregister(process.stdout)
                        stdout_registered = False
                    return False
                if chunk:
                    write_chunk(chunk)
                    if fatal_marker is not None:
                        return True
                    continue
                if stdout_registered:
                    selector.unregister(process.stdout)
                    stdout_registered = False
                return False

        try:
            while True:
                idle_seconds = time.monotonic() - last_output
                wait_timeout = min(1.0, max(0.0, args.idle_timeout_seconds - idle_seconds))

                if stdout_registered:
                    events = selector.select(timeout=wait_timeout)
                    if events:
                        read_available_stdout()
                elif wait_timeout > 0:
                    time.sleep(wait_timeout)

                if fatal_marker is not None:
                    message = (
                        "\n::error::Fatal output detected; terminating command before it can stall: "
                        f"{fatal_marker.decode(errors='replace')}\n"
                    ).encode()
                    output_file.write(message)
                    output_file.flush()
                    sys.stdout.buffer.write(message)
                    sys.stdout.buffer.flush()
                    terminate_process_group(process, process_group_id, args.termination_grace_seconds)
                    break

                if process.poll() is not None and not stdout_registered:
                    break

                idle_seconds = time.monotonic() - last_output
                if idle_seconds >= args.idle_timeout_seconds:
                    timed_out = True
                    message = (
                        f"\n::error::No output for {idle_seconds:.0f}s; terminating stalled command: "
                        f"{' '.join(command)}\n"
                    ).encode()
                    output_file.write(message)
                    output_file.flush()
                    sys.stdout.buffer.write(message)
                    sys.stdout.buffer.flush()
                    terminate_process_group(process, process_group_id, args.termination_grace_seconds)
                    break
        finally:
            selector.close()

    if timed_out or fatal_marker is not None:
        reap_process(process, process_group_id, args.termination_grace_seconds)
        return 124
    return_code = reap_process(process, process_group_id, args.termination_grace_seconds)
    if return_code < 0:
        return 128 + abs(return_code)
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
