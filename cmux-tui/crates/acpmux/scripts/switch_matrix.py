#!/usr/bin/env python3
"""Switch matrix: switch a real chat to another harness's model and back, in every folder kind.

Leo 2026-11-11: "if i switch to a different model in a chat, it should just be able to
seamlesly within the same pane do stuff ... across any and all conditions of
workspaces/folders/models/provides/harnesses". The pane does it with a fork onto the picked
harness (`session/fork` `_meta.acpmux.harness`, `hub/fork.rs` `Retarget`) at the next send;
this script drives the same request through `acpmux session fork --harness H --model M`.

Runs its own acpmux daemon (fork_matrix.py's: own ACPMUX_HOME and socket, never the person's).
For every ordered pair of harnesses and every folder kind it:

  seed     starts a chat on A in that folder and tells it a code word
  switch   forks it onto B: the fork runs B, shows the chat's prompts, and B knows the word
  work     B is told a second word in the fork
  back     forks the fork onto A again: A knows both words
  parent   the first chat is still on A and never heard the second word

Folder kinds: repo (a git checkout), plain (a folder that is no repo), home (no project
folder: the home directory, as a chat with no folder runs).

    python3 -I switch_matrix.py --acpmux "$(command -v acpmux)" \\
        --config ~/.acpmux/config.json \\
        --harness claude=claude/haiku --harness codex=codex/gpt-5.1-codex-mini \\
        --out /tmp/switch-matrix.jsonl
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import random
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fork_matrix import Daemon, Matrix, token  # noqa: E402

FOLDERS = ("repo", "plain", "home")


def folder(kind: str) -> Path:
    if kind == "home":
        return Path.home()
    d = Path(tempfile.mkdtemp(prefix=f"smx-{kind}-"))
    if kind == "repo":
        subprocess.run(["git", "init", "-q", str(d)], check=True)
        (d / "README.md").write_text("switch matrix\n")
        subprocess.run(["git", "-C", str(d), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(d), "-c", "user.name=smx", "-c", "user.email=smx@example.com",
             "commit", "-q", "-m", "init"],
            check=True,
        )
    return d


class Switch(Matrix):
    """One A→B→A switch in one folder."""

    def __init__(self, d: Daemon, a: tuple[str, str], b: tuple[str, str], kind: str, turn_timeout: int):
        super().__init__(d, a[0], a[1], folder(kind), 1, turn_timeout)
        self.a, self.b, self.kind = a, b, kind
        self.tag = f"smx-{a[0]}-{b[0]}-{kind}-{random.randint(1000, 9999)}"
        self.t2 = token("HERON")

    def fork_onto(self, parent: str, name: str, spec: str) -> tuple[bool, str]:
        head, _, model = spec.partition("/")
        args = ["session", "fork", "--json", parent, "-n", name, "--harness", head]
        if model:
            args += ["--model", model]
        p = self.d.run(args, timeout=180)
        if p.returncode != 0:
            return False, f"rc={p.returncode} {(p.stderr or p.stdout).strip()[-300:]}"
        return True, ""

    def harness_of(self, name: str) -> str:
        return str(self.info(name).get("harness") or "")

    def rows(self) -> list[dict]:
        rows: list[dict] = []

        def row(case: str, ok: bool, detail: str) -> bool:
            rows.append({"case": case, "result": "pass" if ok else "fail", "detail": detail[:300]})
            return ok

        chat = f"{self.tag}-chat"
        ok, why = self.new(chat, f"Remember the code word {self.t1}. Reply with just OK.")
        if not row("seed", ok and "ERROR" not in why.upper(), why):
            return rows
        a_harness = self.harness_of(chat)

        switched = f"{self.tag}-b"
        ok, why = self.fork_onto(chat, switched, self.b[1])
        if not ok:
            row("switch", False, f"fork: {why}")
            return rows
        on_b = self.harness_of(switched)
        shows = self.t1 in " ".join(self.prompts(switched))
        ok, reply = self.send(switched, "What is the code word I told you? Reply with just the word.")
        if not row("switch", ok and on_b != a_harness and shows and self.t1 in reply,
                   f"harness={on_b} shows_history={shows} reply={reply[:120]!r}"):
            return rows

        ok, reply = self.send(switched, f"Also remember a second word, {self.t2}. Reply with just OK.")
        if not row("work", ok and "OK" in reply.upper(), reply[:120]):
            return rows

        back = f"{self.tag}-back"
        ok, why = self.fork_onto(switched, back, self.a[1])
        if not ok:
            row("back", False, f"fork: {why}")
            return rows
        ok, reply = self.send(back, "What are the two code words I told you? Reply with just the two words.")
        row("back", ok and self.harness_of(back) == a_harness and self.t1 in reply and self.t2 in reply,
            f"harness={self.harness_of(back)} reply={reply[:160]!r}")

        ok, reply = self.send(chat, "Did I tell you a second code word? Reply with it, or NONE.")
        row("parent", ok and self.harness_of(chat) == a_harness and self.t2 not in reply,
            f"harness={self.harness_of(chat)} reply={reply[:120]!r}")
        return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--acpmux", default="acpmux")
    ap.add_argument("--config", type=Path, default=Path.home() / ".acpmux" / "config.json")
    ap.add_argument("--harness", action="append", required=True, help="LABEL=HARNESS[/MODEL]")
    ap.add_argument("--folder", action="append", choices=FOLDERS, default=[])
    ap.add_argument("--turn-timeout", type=int, default=180)
    ap.add_argument("--env", action="append", default=[], help="NAME=VALUE for the daemon")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--home", type=Path, default=None)
    args = ap.parse_args()
    env = dict(kv.split("=", 1) for kv in args.env)
    home = args.home or Path(tempfile.mkdtemp(prefix="smx-home-"))
    d = Daemon(args.acpmux, home, args.config, env)
    # A prompt from this script is the person's, never an agent's (`acpmux send` reads ACPMUX_FROM).
    d.env.pop("ACPMUX_FROM", None)
    # The daemon refuses a config another user may write (a umask of 002).
    if (home / "config.json").exists():
        os.chmod(home / "config.json", 0o600)
    d.start()
    host = os.uname().nodename
    specs = [tuple(s.split("=", 1)) for s in args.harness]
    failed = 0
    try:
        with args.out.open("a") as out:
            for a, b in itertools.permutations(specs, 2):
                for kind in args.folder or FOLDERS:
                    for r in Switch(d, a, b, kind, args.turn_timeout).rows():
                        r.update({"from": a[0], "to": b[0], "folder": kind, "host": host, "at": int(time.time())})
                        failed += r["result"] != "pass"
                        out.write(json.dumps(r) + "\n")
                        out.flush()
                        print(f"[{a[0]}->{b[0]} {kind:<5}] {r['case']:<7} {r['result']:<5} {r['detail'][:140]}", flush=True)
    finally:
        d.stop()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
