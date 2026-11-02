#!/usr/bin/env python3
"""Time `acpmux ls` (text) against one daemon and one session set, for a before/after.

  ls_bench.py --daemon BIN --client NAME=BIN[,ARGS] ... [--sessions N] [--runs N]

Starts BIN's daemon in a private temporary home with N synthetic sessions (named lanes,
reviewer boxes and sessions with only a generated name, as a busy lane host has), then runs
each client's `ls` (or `ls ARGS`, words split on spaces) --runs times, interleaved so drift
hits every client alike, and prints a Markdown table of p50, p95 and bytes printed. No agent
runs (ACPMUX_AGENT_LAUNCH=deny); the home is removed at the end.
"""

import argparse
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time


def write_sessions(home, count):
    now = int(time.time() * 1000)
    os.makedirs(os.path.join(home, "sessions"), mode=0o700)
    for i in range(count):
        sid = f"01a16c00-0000-7000-8000-{i:012x}"
        kind = i % 8
        harness, name, source = "claude", f"lane-{i}", "named"
        if kind in (1, 2, 3):
            harness, name, source = "codex-review-box", f"review-{i}", "named"
        elif kind == 4:
            harness, name, source = "codex", "codex" if i == 4 else f"codex-{i}", "harness"
        at = now - (count - i) * 1000
        row = {
            "schema": "acpmux.session.v1", "id": sid, "name": name, "harness": harness,
            "model": "sonnet", "cwd": "/tmp", "status": "idle", "createdAt": at, "updatedAt": at,
            "turnCount": 3, "lastSeq": 0, "eventCount": 0, "titleSource": source,
            "lastPrompt": "x" * 400, "tags": {"area": {"value": "acpmux"}},
        }
        d = os.path.join(home, "sessions", sid)
        os.makedirs(d, mode=0o700)
        with open(os.path.join(d, "session.json"), "w") as f:
            json.dump(row, f)
        os.chmod(os.path.join(d, "session.json"), 0o600)


def env_for(home):
    env = {k: os.environ[k] for k in ("PATH", "LANG") if k in os.environ}
    env.update({
        "HOME": os.path.join(home, "home"), "ACPMUX_HOME": home,
        "ACPMUX_SOCKET": os.path.join(home, "acpmux.sock"), "ACPMUX_LOGIN_ENV": "0",
        "ACPMUX_AGENT_LAUNCH": "deny",
    })
    os.makedirs(env["HOME"], exist_ok=True)
    return env


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--daemon", required=True)
    ap.add_argument("--client", action="append", required=True, help="NAME=BIN[,ARGS]")
    ap.add_argument("--sessions", type=int, default=400)
    ap.add_argument("--runs", type=int, default=30)
    a = ap.parse_args()
    home = tempfile.mkdtemp(prefix="acpmux-ls-bench-")
    os.chmod(home, 0o700)
    daemon = None
    try:
        write_sessions(home, a.sessions)
        env = env_for(home)
        daemon = subprocess.Popen([a.daemon, "daemon", "run", "--ready-fd", "1", "--log", "warn"],
                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        for line in daemon.stdout:
            if '"ready":true' in line.replace(" ", ""):
                break
        else:
            sys.exit("daemon did not become ready")
        clients = []
        for spec in a.client:
            name, rest = spec.split("=", 1)
            binary, _, args = rest.partition(",")
            clients.append((name, [binary, "ls", *args.split()]))
        times = {name: [] for name, _ in clients}
        size = {}
        for _ in range(a.runs):
            for name, argv in clients:
                t = time.perf_counter()
                out = subprocess.run(argv, env=env, capture_output=True)
                times[name].append((time.perf_counter() - t) * 1000)
                if out.returncode:
                    sys.exit(f"{name}: {out.stderr.decode()[:300]}")
                size[name] = (len(out.stdout), out.stdout.count(b"\n"))
        print(f"{a.sessions} sessions, {a.runs} runs each, interleaved\n")
        print("| client | p50 ms | p95 ms | bytes | lines |")
        print("|---|---|---|---|---|")
        for name, _ in clients:
            t = sorted(times[name])
            p95 = t[max(0, round(len(t) * 0.95) - 1)]
            print(f"| {name} | {statistics.median(t):.1f} | {p95:.1f} | {size[name][0]} | {size[name][1]} |")
    finally:
        if daemon:
            daemon.send_signal(signal.SIGTERM)
            try:
                daemon.wait(timeout=20)
            except subprocess.TimeoutExpired:
                daemon.kill()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
