#!/usr/bin/env python3
"""Fork matrix: fork real agent chats on every harness and check each fork.

Runs its own acpmux daemon (own ACPMUX_HOME and socket, never the person's),
so it can restart that daemon for the restart case. Each harness gets a chat
with content (a token to remember, a shell tool call), then every case forks
it and checks the result through the acpmux CLI.

    python3 -I fork_matrix.py --acpmux "$(command -v acpmux)" \
        --config ~/.acpmux/config.json --runs 5 \
        --harness claude=claude/haiku --harness codex=codex \
        --out /tmp/fork-matrix.jsonl

Cases (one JSON line per harness, run and case in --out):
  transcript   the fork holds the chat's prompts, replies and tool calls
  recall       a turn in the fork knows the token from turn 1
  original     the chat is unchanged by the fork's turn and still answers
  isolation    a fact told only to the fork never reaches the chat
  concurrent   chat and fork answer at the same time
  fork_of_fork a fork of the fork knows the chat's token and the fork's fact
  busy         a fork taken while the chat runs a turn: forks now, idle, and the chat's turn ends untouched
  restart      after a daemon restart, a fork of the chat still recalls
  empty        a fork of a chat with no turn: a clear refusal or a usable chat
  image        a fork of a chat whose prompt held an image (skipped: no CLI attachment)
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import string
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

CASES = [
    "transcript", "recall", "original", "isolation", "concurrent",
    "fork_of_fork", "busy", "restart", "empty",
]


class Daemon:
    """One isolated acpmux daemon this script starts and stops itself."""

    def __init__(self, acpmux: str, home: Path, config: Path | None, env: dict[str, str], keep_peers: bool = False):
        self.acpmux = acpmux
        self.home = home
        self.sock = Path(tempfile.mkdtemp(prefix="fmx-sock-")) / "a.sock"
        self.env = dict(os.environ)
        self.env.update(env)
        self.env["ACPMUX_HOME"] = str(home)
        self.env["ACPMUX_SOCKET"] = str(self.sock)
        # Never let the person's own session context leak into this daemon.
        for k in ("ACPMUX_ENV", "ACPMUX_SESSION_ID", "ACPMUX_SESSION_NAME", "ACPMUX_CALLER_TOKEN"):
            self.env.pop(k, None)
        home.mkdir(parents=True, exist_ok=True)
        os.chmod(home, 0o700)
        if config and config.exists():
            cfg = json.loads(config.read_text())
            # Peers are other machines' daemons: this run stays on this one.
            if not keep_peers:
                cfg["peers"] = {} if isinstance(cfg.get("peers"), dict) else []
            (home / "config.json").write_text(json.dumps(cfg))
        self.proc: subprocess.Popen | None = None
        self.log = open(home / "matrix-daemon.log", "ab")

    def start(self) -> None:
        self.proc = subprocess.Popen(
            [self.acpmux, "daemon", "run", "--log", "info"],
            env=self.env, stdout=self.log, stderr=self.log, start_new_session=True,
        )
        deadline = time.time() + 30
        while time.time() < deadline:
            if self.run(["daemon", "status"], timeout=10).returncode == 0:
                return
            time.sleep(0.5)
        raise RuntimeError("isolated acpmux daemon did not come up")

    def stop(self) -> None:
        self.run(["daemon", "shutdown"], timeout=30)
        if self.proc:
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                self.proc.wait(timeout=10)
            self.proc = None

    def restart(self) -> None:
        self.stop()
        self.start()

    def run(self, args: list[str], timeout: float = 240, stdin: str | None = None) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(
                [self.acpmux, *args], env=self.env, input=stdin, capture_output=True,
                text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired as e:
            return subprocess.CompletedProcess(e.cmd, 124, e.stdout or "", f"timeout after {timeout}s")

    def json(self, args: list[str], timeout: float = 240) -> tuple[int, dict, str]:
        p = self.run(["--json", *args] if args[0] not in ("session",) else [args[0], "--json", *args[1:]], timeout)
        try:
            return p.returncode, json.loads(p.stdout or "{}"), p.stderr
        except json.JSONDecodeError:
            # Streams print several objects; the last is the summary.
            last = {}
            for line in (p.stdout or "").splitlines():
                try:
                    last = json.loads(line)
                except json.JSONDecodeError:
                    continue
            return p.returncode, last if isinstance(last, dict) else {}, p.stderr + p.stdout[-400:]


# A refusal must say why in words a person can act on; a bare agent error is a failure.
REASONS = ("no turn", "cannot fork", "could not fork", "working", "turn ends")


def clear_refusal(why: str) -> bool:
    return "timeout" not in why and any(r in why for r in REASONS) and "could not fork this chat: Internal error" not in why


def token(prefix: str) -> str:
    return prefix + "-" + "".join(random.choices(string.ascii_uppercase + string.digits, k=6))


class Matrix:
    def __init__(self, d: Daemon, harness: str, model: str, cwd: Path, run: int, turn_timeout: int):
        # HARNESS[/MODEL]@PEER: the chat runs on that acpmux peer (another computer); every
        # fork of it is forwarded there (server/peer_forward.rs).
        model, _, self.host = model.partition("@")
        self.d, self.harness, self.model, self.cwd, self.run_no = d, harness, model, cwd, run
        self.turn_timeout = turn_timeout
        self.tag = f"fmx-{harness}-{run}-{random.randint(1000, 9999)}"
        self.t1 = token("ZEBRA")
        self.u = token("OTTER")

    # -- acpmux helpers -------------------------------------------------
    def new(self, name: str, prompt: str | None) -> tuple[bool, str]:
        cwd = "/tmp" if self.host else str(self.cwd)
        args = ["new", "-d", "-n", name, "-m", self.model, "--cwd", cwd, "--policy", "approve-all"]
        if self.host:
            args += ["--host", self.host]
        if prompt:
            args += ["--timeout", str(self.turn_timeout), "--stall", "150", "-q", prompt]
        rc, out, err = self.d.json(args, timeout=self.turn_timeout + 60)
        return rc == 0, (out.get("reply") or "") if rc == 0 else f"rc={rc} {err.strip()[-300:]}"

    def send(self, name: str, prompt: str) -> tuple[bool, str]:
        rc, out, err = self.d.json(["send", "--timeout", str(self.turn_timeout), "--stall", "150", name, prompt], timeout=self.turn_timeout + 60)
        if rc != 0:
            return False, f"rc={rc} {err.strip()[-300:]}"
        # The turn's reply as the session's log holds it: `acpmux send`'s own reply can miss a
        # fast agent's first chunks (seen with codex-app-server), which is no fork's fault.
        # The log's last chunk can land just after `send` returns: settle, then keep the
        # longer of the two (the log misses nothing at the start, the CLI nothing at the end).
        time.sleep(1)
        logged, said = self.last_reply(name), str(out.get("reply") or "")
        return True, logged if len(logged) >= len(said) else said

    def last_reply(self, name: str) -> str:
        events = self.events(name)
        start = max((i for i, e in enumerate(events) if e.get("kind") == "user_message"), default=-1)
        text = []
        for e in events[start + 1 :]:
            if e.get("kind") == "agent_message_chunk":
                update = ((e.get("msg") or {}).get("params") or {}).get("update") or {}
                text.append(str((update.get("content") or {}).get("text") or ""))
        return "".join(text)

    def fork(self, parent: str, name: str) -> tuple[bool, str]:
        p = self.d.run(["session", "fork", "--json", parent, "-n", name], timeout=120)
        if p.returncode != 0:
            return False, f"rc={p.returncode} {(p.stderr or p.stdout).strip()[-300:]}"
        return True, ""

    def events(self, name: str) -> list[dict]:
        p = self.d.run(["session", "tail", "--json", "--last", "2000", name], timeout=60)
        out = []
        for line in p.stdout.splitlines():
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        return out

    def info(self, name: str) -> dict:
        p = self.d.run(["session", "info", "--json", name], timeout=30)
        try:
            return json.loads(p.stdout)
        except json.JSONDecodeError:
            return {}

    def prompts(self, name: str) -> list[str]:
        return [str((e.get("msg") or {}).get("text") or "") for e in self.events(name) if e.get("kind") == "user_message"]

    def tool_calls(self, name: str) -> int:
        return sum(1 for e in self.events(name) if e.get("kind") in ("tool_call", "claude.tool_use") or
                   (e.get("kind") == "claude.assistant" and '"tool_use"' in json.dumps(e.get("msg"))))

    def wait_idle(self, name: str, limit: float) -> bool:
        deadline = time.time() + limit
        while time.time() < deadline:
            if self.info(name).get("status") in ("ready", "idle"):
                return True
            time.sleep(1)
        return False

    # -- the chat every case forks ---------------------------------------
    def seed(self) -> tuple[bool, str]:
        self.parent = f"{self.tag}-chat"
        ok, why = self.new(self.parent, f"Remember the code word {self.t1}. Reply with just OK.")
        if not ok and "connect" in why:  # the daemon's socket was not ready yet: once more
            time.sleep(3)
            self.parent = f"{self.tag}-chat2"
            ok, why = self.new(self.parent, f"Remember the code word {self.t1}. Reply with just OK.")
        if not ok:
            return False, f"turn 1: {why}"
        # A harness that answers with an error text (a model the account lacks) is no chat to fork.
        if "OK" not in why.upper() or "ERROR" in why.upper():
            return False, f"turn 1 reply {why[:200]!r}"
        ok, why = self.send(self.parent, "Use your shell or terminal tool to run exactly this command: echo TOOL-CHECK. Then reply with just DONE.")
        if not ok:
            return False, f"turn 2: {why}"
        self.parent_tools = self.tool_calls(self.parent)
        # From here on the chat answers from its conversation only: an agent that may search
        # the disk (OpenCode's default agent did) finds earlier runs' code words there. Forks
        # take the chat's policy.
        p = self.d.run(["session", "set", self.parent, "policy=deny-all"], timeout=30)
        if p.returncode != 0:
            return False, f"policy deny-all: {(p.stderr or p.stdout).strip()[-200:]}"
        self.parent_prompts = self.prompts(self.parent)
        return True, f"prompts={len(self.parent_prompts)} tool_events={self.parent_tools}"

    def recall_ok(self, reply: str, *tokens: str) -> bool:
        return all(t in reply for t in tokens)

    # -- cases ----------------------------------------------------------
    def case_transcript(self) -> tuple[str, str]:
        self.fork1 = f"{self.tag}-f1"
        ok, why = self.fork(self.parent, self.fork1)
        if not ok:
            # A harness whose agent offers no session/fork is refused with that reason: the
            # palette then says so too. Recorded apart from a failure.
            if "does not offer session/fork" in why:
                self.unsupported = True
                return "unsupported", why[why.find("message") :][:160]
            return "fail", f"fork: {why}"
        prompts = self.prompts(self.fork1)
        missing = [p for p in self.parent_prompts if p not in prompts]
        replies = sum(1 for e in self.events(self.fork1) if e.get("kind") in ("agent_message_chunk", "agent_message_chunk.replay"))
        tools = self.tool_calls(self.fork1)
        info = self.info(self.fork1)
        problems = []
        if missing:
            problems.append(f"missing prompts {missing}")
        if replies == 0:
            problems.append("no agent replies copied")
        if self.parent_tools and not tools:
            problems.append("tool calls not copied")
        if info.get("parentId") != self.info(self.parent).get("sessionId"):
            problems.append(f"parentId {info.get('parentId')}")
        return ("fail", "; ".join(problems)) if problems else ("pass", f"prompts={len(prompts)} replies={replies} tools={tools}")

    def case_recall(self) -> tuple[str, str]:
        ok, reply = self.send(self.fork1, f"FORKMARK. What code word did I give you first? Also remember a second code word {self.u}. Reply with only the first code word.")
        if not ok:
            return "fail", reply
        return ("pass", reply[:80]) if self.recall_ok(reply, self.t1) else ("fail", f"reply {reply[:200]!r}")

    def case_original(self) -> tuple[str, str]:
        prompts = self.prompts(self.parent)
        if prompts != self.parent_prompts:
            return "fail", f"chat prompts changed: {prompts[len(self.parent_prompts):]}"
        if any("FORKMARK" in p for p in prompts):
            return "fail", "the fork's prompt reached the chat"
        ok, reply = self.send(self.parent, "What code word did I give you? Reply with only the code word.")
        if not ok:
            return "fail", reply
        return ("pass", reply[:80]) if self.recall_ok(reply, self.t1) else ("fail", f"reply {reply[:200]!r}")

    def case_isolation(self) -> tuple[str, str]:
        ok, reply = self.send(self.parent, "Did I give you a code word that starts with OTTER? If yes reply with it, else reply NONE.")
        if not ok:
            return "fail", reply
        return ("fail", f"chat knows the fork's token: {reply[:120]!r}") if self.u in reply else ("pass", reply[:80])

    def case_concurrent(self) -> tuple[str, str]:
        res: dict[str, tuple[bool, str]] = {}

        def go(name: str) -> None:
            res[name] = self.send(name, "Reply with only the first code word I gave you.")

        ts = [threading.Thread(target=go, args=(n,)) for n in (self.parent, self.fork1)]
        t0 = time.time()
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        bad = {n: r for n, r in res.items() if not (r[0] and self.t1 in r[1])}
        return ("fail", json.dumps(bad)[:300]) if bad else ("pass", f"both answered in {time.time() - t0:.1f}s")

    def case_fork_of_fork(self) -> tuple[str, str]:
        ff = f"{self.tag}-ff"
        ok, why = self.fork(self.fork1, ff)
        if not ok:
            return "fail", f"fork: {why}"
        ok, reply = self.send(ff, "Reply with the first code word and the second code word, separated by a space, nothing else.")
        if not ok:
            return "fail", reply
        return ("pass", reply[:80]) if self.recall_ok(reply, self.t1, self.u) else ("fail", f"reply {reply[:200]!r}")

    def case_busy(self) -> tuple[str, str]:
        p = self.d.run(["send", "--no-wait", self.parent, "Write the numbers from 1 to 150 in words, one per line. No other text."], timeout=60)
        if p.returncode != 0:
            return "fail", f"long prompt: {p.stderr.strip()[-200:]}"
        deadline = time.time() + 30
        while time.time() < deadline and self.info(self.parent).get("status") not in ("working", "running", "busy"):
            time.sleep(0.3)
        status = self.info(self.parent).get("status")
        fb = f"{self.tag}-busy"
        ok, why = self.fork(self.parent, fb)
        outcome = "forked" if ok else f"refused ({why})"
        if not self.wait_idle(self.parent, self.turn_timeout + 60):
            return "fail", f"chat never finished its turn after a busy fork ({outcome})"
        if not ok:
            # A working chat forks now, as it is (2026-10-21): any refusal is the bug.
            return "fail", f"status={status}; {outcome}"
        if self.info(fb).get("status") not in ("ready", "idle"):
            return "fail", f"status={status}; the fork is not idle at once: {self.info(fb).get('status')}"
        # The chat's turn went on untouched: its long answer reached its end.
        if "fifty" not in self.last_reply(self.parent).lower():
            return "fail", f"status={status}; the chat's turn was cut: {self.last_reply(self.parent)[-120:]!r}"
        ok2, reply = self.send(fb, "Reply with only the first code word I gave you.")
        if not ok2:
            return "fail", f"status={status}; fork's turn: {reply}"
        if not self.recall_ok(reply, self.t1):
            return "fail", f"status={status}; reply {reply[:200]!r}"
        ok3, reply3 = self.send(self.parent, "Reply with just OK.")
        return ("pass", f"status={status}; forked and recalled") if ok3 else ("fail", f"chat after busy fork: {reply3}")

    def case_restart(self) -> tuple[str, str]:
        self.d.restart()
        fr = f"{self.tag}-rs"
        ok, why = self.fork(self.parent, fr)
        if not ok:
            return "fail", f"fork after restart: {why}"
        ok, reply = self.send(fr, "Reply with only the first code word I gave you.")
        if not ok:
            return "fail", reply
        if not self.recall_ok(reply, self.t1):
            return "fail", f"reply {reply[:200]!r}"
        ok, reply = self.send(self.parent, "Reply with only the first code word I gave you.")
        return ("pass", "fork and chat recall after restart") if ok and self.t1 in reply else ("fail", f"chat after restart: {reply[:200]!r}")

    def case_empty(self) -> tuple[str, str]:
        e = f"{self.tag}-empty"
        ok, why = self.new(e, None)
        if not ok:
            return "fail", f"empty chat: {why}"
        ok, why = self.fork(e, f"{e}-f")
        if not ok:
            return ("pass", f"refused: {why[:160]}") if clear_refusal(why) else ("fail", f"refused without a clear reason: {why}")
        ok, reply = self.send(f"{e}-f", "Reply with just OK.")
        return ("pass", "forked an empty chat; it answers") if ok else ("fail", f"empty fork unusable: {reply}")

    def run_all(self, only: list[str]) -> list[dict]:
        rows = []
        t0 = time.time()
        ok, why = self.seed()
        rows.append({"case": "seed", "result": "pass" if ok else "fail", "detail": why, "secs": round(time.time() - t0, 1)})
        if not ok:
            return rows
        needs_fork1 = {"recall", "original", "isolation", "concurrent", "fork_of_fork"}
        have_fork1 = False
        for case in CASES:
            if only and case not in only and not (case == "transcript" and needs_fork1 & set(only)):
                continue
            if getattr(self, "unsupported", False) and case != "empty":
                rows.append({"case": case, "result": "n/a", "detail": "the harness cannot fork"})
                continue
            if case in needs_fork1 and not have_fork1:
                rows.append({"case": case, "result": "fail", "detail": "no fork to test (transcript failed)"})
                continue
            t0 = time.time()
            try:
                result, detail = getattr(self, f"case_{case}")()
            except Exception as ex:  # a case's crash is its failure, the rest still run
                result, detail = "fail", f"exception {ex!r}"
            if case == "transcript":
                have_fork1 = hasattr(self, "fork1") and result == "pass"
            rows.append({"case": case, "result": result, "detail": detail, "secs": round(time.time() - t0, 1)})
        return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--acpmux", default=shutil.which("acpmux") or "acpmux")
    ap.add_argument("--config", type=Path, default=Path.home() / ".acpmux" / "config.json")
    ap.add_argument("--harness", action="append", required=True, help="LABEL=HARNESS[/MODEL]")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--case", action="append", default=[])
    ap.add_argument("--turn-timeout", type=int, default=180)
    ap.add_argument("--env", action="append", default=[], help="NAME=VALUE for the daemon")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--home", type=Path, default=None)
    ap.add_argument("--keep-peers", action="store_true", help="keep config.json's peers (for HARNESS@PEER chats)")
    args = ap.parse_args()
    env = dict(kv.split("=", 1) for kv in args.env)
    home = args.home or Path(tempfile.mkdtemp(prefix="fmx-home-"))
    cwd = Path(tempfile.mkdtemp(prefix="fmx-cwd-"))
    d = Daemon(args.acpmux, home, args.config, env, keep_peers=args.keep_peers)
    d.start()
    host = os.uname().nodename
    try:
        with args.out.open("a") as out:
            for run in range(1, args.runs + 1):
                for spec in args.harness:
                    label, model = spec.split("=", 1)
                    m = Matrix(d, label, model, cwd, run, args.turn_timeout)
                    for row in m.run_all(args.case):
                        row.update({"harness": label, "model": model, "run": run, "host": host, "at": int(time.time())})
                        out.write(json.dumps(row) + "\n")
                        out.flush()
                        print(f"[{label} run {run}] {row['case']:<13} {row['result']:<5} {row['detail'][:140]}", flush=True)
    finally:
        d.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
