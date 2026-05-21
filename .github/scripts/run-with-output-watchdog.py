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


def terminate_process_group(process: subprocess.Popen[bytes], grace_seconds: float) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGTERM)
    except ProcessLookupError:
        return
    except OSError:
        process.terminate()

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return
        time.sleep(0.2)

    if process.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except ProcessLookupError:
        return
    except OSError:
        process.kill()


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

    with output_path.open("wb") as output_file:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        try:
            while True:
                events = selector.select(timeout=1.0)
                if events:
                    chunk = os.read(process.stdout.fileno(), 8192)
                    if chunk:
                        output_file.write(chunk)
                        output_file.flush()
                        sys.stdout.buffer.write(chunk)
                        sys.stdout.buffer.flush()
                        last_output = time.monotonic()
                    else:
                        selector.unregister(process.stdout)
                        break

                if process.poll() is not None:
                    remaining = process.stdout.read()
                    if remaining:
                        output_file.write(remaining)
                        output_file.flush()
                        sys.stdout.buffer.write(remaining)
                        sys.stdout.buffer.flush()
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
                    terminate_process_group(process, args.termination_grace_seconds)
                    break
        finally:
            selector.close()

    if timed_out:
        return 124
    return_code = process.wait()
    if return_code < 0:
        return 128 + abs(return_code)
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
