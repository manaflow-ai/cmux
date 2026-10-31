#!/usr/bin/env python3
"""The pool's weekly headroom from one real Claude Code response.

usage: headroom_probe.py [--model claude-haiku-5-5] [--base-url URL] [--claude PATH]
  --base-url  the route to probe (the campaign passes the steps' --base-url,
              so the reading is from their pool); default: this environment's
Runs `claude -p` once on the cheapest model with ANTHROPIC_LOG=debug, which
prints each response's real headers on stdout, reads the
anthropic-ratelimit-unified-7d-* headers and prints 1 - utilization (0 when
the 7d status is not "allowed"). Exits 1, printing nothing on stdout, when
the call fails or no response carries a 7d utilization: the campaign then
counts the headroom unknown and starts nothing (fail closed). Nothing here
makes an HTTP request or a header itself.

One reading covers only the upstream account the gateway routed that one
request to; another request may land on another account with less room.
team_eval.py's campaign keeps a window of readings (this probe's and the
steps' own traffic's) and gates on their minimum, so it sees only the
accounts the pool rotated its requests through.

The same parser reads a run's own traffic: team_eval.py runs Claude Code
with ANTHROPIC_LOG=debug and passes the lines it did not parse as JSON
(arm L's stdout, acpmux's `[non-json stdout]` records) to
`ratelimit_readings`.
"""
import argparse
import os
import re
import subprocess
import sys
import time

HEADER = re.compile(r'"?(anthropic-ratelimit-unified-[a-z0-9-]+|request-id)"?\s*:\s*"([^"]*)"')
# acpmux logs a harness's non-JSON stdout line under this prefix.
ACPMUX_PREFIX = "[non-json stdout] "


def _num(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x if x == x else None  # NaN is no number


class RatelimitParser:
    """ANTHROPIC_LOG=debug lines in, one reading per response out, as the
    lines arrive: the unified headers of each headers block (a block ends at
    a line starting with `}`), once per request id (the log prints a
    response's headers twice). A reading's `at` is its block's last header
    line's ms, else `at`, else now."""

    def __init__(self, at=None):
        self.at, self.cur, self.cur_at, self.last_id = at, {}, None, None

    def feed(self, line, ms=None):
        """The readings `line` completes ([] or one)."""
        if line.startswith(ACPMUX_PREFIX):
            line = line[len(ACPMUX_PREFIX):]
        m = HEADER.search(line)
        if m:
            self.cur[m.group(1)] = m.group(2)
            self.cur_at = ms
            return []
        return self.close() if line.lstrip().startswith("}") else []

    def close(self):
        cur, out = self.cur, []
        if any(k.startswith("anthropic-ratelimit-unified-") for k in cur):
            g = lambda name: cur.get("anthropic-ratelimit-unified-" + name)
            at = self.cur_at if self.cur_at is not None else (self.at if self.at is not None else int(time.time() * 1000))
            r = {"at": at, "request_id": cur.get("request-id"), "status": g("status"),
                 "7d_utilization": _num(g("7d-utilization")), "7d_status": g("7d-status"),
                 "5h_utilization": _num(g("5h-utilization")), "5h_status": g("5h-status")}
            if not (r["request_id"] and r["request_id"] == self.last_id):
                out.append(r)
            self.last_id = r["request_id"]
        self.cur = {}
        return out


def ratelimit_readings(lines, at=None):
    """Every reading of `lines` (text lines or (ms, line) pairs): RatelimitParser."""
    p, out = RatelimitParser(at), []
    for item in lines:
        ms, line = item if isinstance(item, tuple) else (None, item)
        out += p.feed(line, ms)
    return out + p.close()


def reading_headroom(r):
    """1 - the 7d utilization; 0 when the 7d status is not "allowed"; None
    when the reading has no 7d utilization."""
    if r.get("headroom") is not None:
        return r["headroom"]
    if r.get("7d_status") is not None and r["7d_status"] != "allowed":
        return 0.0
    if r.get("7d_utilization") is None:
        return None
    return max(0.0, min(1.0, 1 - r["7d_utilization"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="claude-haiku-5-5", help="the cheapest model")
    ap.add_argument("--base-url", default="", help="the route to probe (default: this environment's)")
    ap.add_argument("--claude", default="claude")
    ap.add_argument("--timeout", type=float, default=120)
    opts = ap.parse_args()
    env = dict(os.environ, ANTHROPIC_LOG="debug")
    scratch = None
    if opts.base_url:
        # The steps' route signs its requests itself: as team-eval.sh does, it
        # gets a placeholder key and none of this host's credentials, under a
        # scratch HOME and config dir, so no settings.json env, apiKeyHelper
        # or login of this host's sends a credential or another route.
        import shutil
        import tempfile
        scratch = tempfile.mkdtemp(prefix="headroom-probe.")
        for k in [k for k in env if k.startswith(("ANTHROPIC_", "CLAUDE_CODE_", "AWS_", "GOOGLE_", "CLOUD_ML_",
                                                   "VERTEX_"))]:
            env.pop(k)
        env.update(ANTHROPIC_LOG="debug", HOME=scratch, CLAUDE_CONFIG_DIR=os.path.join(scratch, ".claude"),
                   ANTHROPIC_BASE_URL=opts.base_url, ANTHROPIC_API_KEY="sk-ant-placeholder-the-route-signs",
                   DISABLE_AUTOUPDATER="1")
    try:
        r = subprocess.run([opts.claude, "-p", "reply with the word ok", "--model", opts.model],
                           capture_output=True, text=True, env=env, timeout=opts.timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        sys.exit(f"headroom_probe: claude -p failed: {e}")
    finally:
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
    got = [x for x in ratelimit_readings(r.stdout.splitlines()) if reading_headroom(x) is not None]
    if not got:
        sys.exit(f"headroom_probe: no anthropic-ratelimit-unified-7d header in the response (claude rc {r.returncode})")
    last = got[-1]
    print(f"{reading_headroom(last):.4f}")
    print(f"headroom_probe: 7d utilization {last['7d_utilization']} status {last['7d_status']}, "
          f"5h {last['5h_utilization']}, request {last['request_id']} (one upstream account)", file=sys.stderr)


if __name__ == "__main__":
    main()
