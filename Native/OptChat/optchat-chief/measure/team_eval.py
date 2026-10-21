#!/usr/bin/env python3
"""One run of the coordinator-mode eval: one task, one arm, a real Chief.

cmuxterm-hq knowledge/inspiration/coordinator-mode-eval.md has the design. A
run starts the production trio on a scratch home, as chief_driver.py does
(cmux-tui --headless owns the Chief conversation, optchat-chief host starts
its own acpmux), checks the task's base out with no history, posts the brief
and the scripted follow-ups as `user_local` at their times, and records every
message with the time this script first saw it. It never pushes, opens a PR
or runs a fleet step: `gh` and `cmux-ci` are stubs on the run's PATH that
record their calls.

Arms (the profile and env differ, nothing else):
  A   Chief heads-down: no spawn or tell, receipts off.
  B   Front desk always delegates: receipts on, spawn and tell, every task to
      a subagent.
  B2  Front desk may act: receipts on, spawn and tell, and the rule that work
      fitting a few quick tool calls is done inline, the rest handed off.
  L   Lossy heads-down: no Chief. One plain Claude Code session (stream-json,
      as acpmux runs Claude Code) in the task repo, with its own
      auto-compaction; messages sent while it works wait for its next turn.

usage:
  team_eval.py run --task ID --arm A|B|B2|L --bins DIR --repo DIR --out DIR
      [--tasks FILE] [--env K=V ...] [--budget-usd 40] [--max-minutes 60] [--keep-repo DIR]
  --bins   optchat-chief, cmux-tui (also as cmux) and acpmux
  --repo   a cmux checkout that has the task's base and reference commits
Writes OUT/run.json (timeline, cost, flags), OUT/conversation.json,
OUT/traces/, OUT/diff.patch and OUT/stubs.jsonl. Scoring that needs a judge
is team_eval_score.py; the numbers that need none are in run.json.

Every arm runs claude-opus-5-5 at medium effort (PIN, the one setting the
Chief is used with): the env pins it, and a run whose real responses or
Chief turns show another model or effort fails (run.json `pin`, exit 3).
The compactor keeps its production model and is recorded, not pinned.

A run stops at --budget-usd of real spend: the live total of its Claude
Code transcripts (LiveMeter, mid-turn too) or the trace's, the higher.

  team_eval.py campaign --ref SHA --base-url URL --task ID... --arm ARM...
      [--reps 1] [--cap-usd 800] [--ledger FILE] [--run-budget 25]
      [--margin 12] [--parallel 3] --out DIR
runs every task x arm x rep as a fleet step (scripts/measure/team-eval.sh)
under one spend cap for the whole eval, pilot and full run alike: the
ledger (default ~/.local/state/team-eval/ledger.json) holds what each run
spent and what each running one may still spend. A run starts only when
spent + reserved + its budget + margin stays under the cap; its budget is
cut to fit, and none starts below $5. A run whose spend is unknown (no
TEAM-EVAL line) counts its whole reservation. The margin covers what is
still in flight when a run stops (about $3 per Opus response: the Chief
and its subagents). Re-running a campaign skips finished runs and starts a
new attempt (its own step key) of the others; an older attempt keeps its
reservation until it settles. A run that failed (`ok` false: a pin
failure, processes left) is recorded as done with its spend and `failed`.
"""
import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PIN = {"model": "claude-opus-5-5", "effort": "medium"}
PIN_ENV = {"OPTCHAT_CHIEF_MODEL": PIN["model"], "OPTCHAT_CHIEF_EFFORT": PIN["effort"],
           "OPTCHAT_SUBAGENT_MODEL": PIN["model"], "OPTCHAT_SUBAGENT_EFFORT": PIN["effort"]}
CHIEF = "agent_mux"
DESK_PREFIX = "voice:desk:"

ARMS = {
    "A": {"tools": "", "grace": "0", "rule": ""},
    "B": {
        "tools": "spawn,tell",
        "grace": "5",
        "rule": (
            "You are the front desk and the dispatcher of this Chief. Answer every message from "
            "the person quickly. You never do the task's work yourself: every piece of work goes "
            "to a subagent with spawn (give it the repo path and the whole task), and follow-ups "
            "about it go to that subagent with tell. You route, track and keep the person told."
        ),
    },
    "B2": {
        "tools": "spawn,tell",
        "grace": "5",
        "rule": (
            "You are the front desk and the dispatcher of this Chief. Answer every message from "
            "the person quickly. Do the work yourself when it fits in a few quick tool calls: a "
            "lookup, a one-line fix, answering from memory, checking a status. Hand anything "
            "longer, parallel or blocking (a multi-file change, a test run, a build) to a subagent "
            "with spawn, give it the repo path and the whole task, then track it and keep the "
            "person told. Never spend a long turn heads-down while the person waits."
        ),
    },
}


def now_ms():
    return int(time.time() * 1000)


def load_task(path, task_id):
    tasks = json.load(open(path))["tasks"]
    for t in tasks:
        if t["id"] == task_id:
            return t
    raise SystemExit(f"no task {task_id} in {path}")


def text_of(message):
    return "\n".join(p.get("text", "") for p in message.get("parts", []) if p.get("type") == "text")


def is_desk(message):
    return (message.get("client_msg_id") or "").startswith(DESK_PREFIX)


def rises(running):
    """Each step's own cost from a running total (Claude Code's
    `total_cost_usd`): the rise since the last value, or the whole value
    when it went down (the process restarted)."""
    out, prev = [], None
    for c in running:
        out.append(c - prev if prev is not None and c + 1e-12 >= prev else c)
        prev = c
    return out


def trace_cost(events):
    """API-equivalent dollars of every session in a trace: Chief turns,
    subagent answers and compactor nodes. A turn.end's and a
    subagent.answer's cost_usd is its process's running total (acpmux passes
    Claude Code's total_cost_usd), so each counts only its rise: the Chief's
    turns as one session, each subagent (by id) as its own, the way
    usage.rs folds the ledger. A compactor node is its own process.
    turn.end does not name its session, so when the Chief's kept session is
    replaced by one whose total starts at or above the old one's, only the
    rise counts and this reads low; LiveMeter (per message) is the
    authority for the budget and the ledger, this the cross-check."""
    turns, subs, nodes = [], {}, 0.0
    for e in events:
        c = e.get("cost_usd")
        if c is None:
            continue
        if e.get("ev") == "turn.end":
            turns.append(c)
        elif e.get("ev") == "subagent.answer":
            subs.setdefault(e.get("id"), []).append(c)
        elif e.get("ev") == "node":
            nodes += c
    total = {"turns": sum(rises(turns)), "subagents": sum(sum(rises(v)) for v in subs.values()), "compactor": nodes}
    total["all"] = sum(total.values())
    return {k: round(v, 4) for k, v in total.items()}


# List prices per million tokens: input, cache write 1h, cache write 5m, cache read, output.
from unii_bench import PRICES  # noqa: E402


def usage_usd(model, usage):
    """One API response's dollars at list prices. A model not in PRICES is
    priced as the dearest; a cache write with no 1h/5m split as 1h."""
    p = PRICES.get(model) or max(PRICES.values())
    split = usage.get("cache_creation") or {}
    w1h, w5m = split.get("ephemeral_1h_input_tokens"), split.get("ephemeral_5m_input_tokens")
    if w1h is None and w5m is None:
        w1h, w5m = usage.get("cache_creation_input_tokens") or 0, 0
    return ((usage.get("input_tokens") or 0) * p[0] + (w1h or 0) * p[1] + (w5m or 0) * p[2]
            + (usage.get("cache_read_input_tokens") or 0) * p[3] + (usage.get("output_tokens") or 0) * p[4]) / 1e6


class LiveMeter:
    """Real spend while the run runs, mid-turn too: every Claude Code
    transcript under `roots` (`projects/**/*.jsonl`, written as each response
    arrives), each assistant message's usage at list prices, once per message
    id (streamed copies repeat it; the last wins). The trace's cost comes
    only at a turn's end, so the budget reads this."""

    def __init__(self, roots):
        self.roots = [r for r in roots if r]
        self.offsets = {}
        self.by_id = {}
        self.models = set()

    def usd(self):
        for root in self.roots:
            for dirpath, _, files in os.walk(root):
                if "projects" not in dirpath.split(os.sep):
                    continue
                for f in files:
                    if f.endswith(".jsonl"):
                        self._read(os.path.join(dirpath, f))
        return sum(self.by_id.values())

    def _read(self, path):
        try:
            with open(path, "rb") as fh:
                fh.seek(self.offsets.get(path, 0))
                chunk = fh.read()
        except OSError:
            return
        whole = chunk[: chunk.rfind(b"\n") + 1]
        self.offsets[path] = self.offsets.get(path, 0) + len(whole)
        for line in whole.splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            msg = e.get("message") if isinstance(e, dict) else None
            if e.get("type") != "assistant" or not isinstance(msg, dict) or not msg.get("usage"):
                continue
            self.by_id[msg.get("id") or f"{path}:{len(self.by_id)}"] = usage_usd(msg.get("model"), msg["usage"])
            if msg.get("model") and msg["model"] != "<synthetic>":
                self.models.add(msg["model"])


def is_pinned_model(model):
    """The pinned model, or a dated id of it (claude-opus-5-5-YYYYMMDD)."""
    return model == PIN["model"] or (model or "").startswith(PIN["model"] + "-")


def pin_check(env, models, events=()):
    """Whether the run used only PIN: the env it was given, every model that
    answered and every effort asked for. `models` are the transcripts' (arm
    L, which runs no compactor); a Chief run passes its trace instead: the
    requests of turns and subagents, each turn's model and effort, and each
    spawn's `effort` argument (which overrides the subagent default; the
    trace has tool args with OPTCHAT_TRACE_FULL=1). Compactor nodes (their
    own model, by design) are recorded apart, never checked."""
    bad = [f"{k}={env.get(k)}" for k, v in PIN_ENV.items() if env.get(k) != v]
    seen = set(models)
    efforts = set()
    for e in events:
        if (e.get("ev") == "request" and e.get("model") and e["model"] != "<synthetic>"
                and (e.get("turn") or e.get("subagent"))):
            seen.add(e["model"])
        elif e.get("ev") == "turn.end":
            if e.get("model") and e["model"] != "<synthetic>":
                seen.add(e["model"])
            if e.get("effort"):
                efforts.add(e["effort"])
        elif e.get("ev") == "tool" and (e.get("name") or "").split("__")[-1] == "spawn":
            if "args" not in e:
                bad.append("a spawn's args are not in the trace (OPTCHAT_TRACE_FULL=1)")
            elif (e.get("args") or {}).get("effort"):
                efforts.add(e["args"]["effort"])
    bad += [f"model {m}" for m in sorted(seen) if not is_pinned_model(m)]
    bad += [f"effort {x}" for x in sorted(efforts) if x != PIN["effort"]]
    return {"want": PIN, "models": sorted(seen), "turn_efforts": sorted(efforts),
            "compactor_models": sorted({e["model"] for e in events if e.get("ev") == "node" and e.get("model")}),
            "ok": not bad and bool(seen), "bad": bad or ([] if seen else ["no model answered"])}


def followup_skew(sent, task):
    """Seconds each follow-up went out after its schedule (`at` after the brief)."""
    return {f["id"]: round((sent[f["id"]] - sent["brief"]) / 1000 - f["at"], 1)
            for f in task["followups"] if f["id"] in sent and "brief" in sent}


def timeline(sent, messages, arrivals):
    """The numbers that need no judge. `sent` maps a prompt id (brief, then
    follow-up ids) to the ms it was posted; `messages` are the conversation's
    messages; `arrivals` maps a message id to the ms this run first saw it.
    For each prompt: the first Chief message after it (a desk receipt counts
    here and is marked), and the first one that is not a receipt."""
    chief = sorted(
        ((arrivals.get(m["id"], 0), m) for m in messages if m.get("author") == CHIEF and text_of(m).strip()),
        # Messages seen in the same ms keep their conversation order.
        key=lambda tm: (tm[0], tm[1].get("seq", 0)),
    )
    order = sorted(sent.items(), key=lambda kv: kv[1])
    out = {}
    for pid, at in order:
        after = [(t, m) for t, m in chief if t >= at]
        first = after[0] if after else None
        first_chief = next(((t, m) for t, m in after if not is_desk(m)), None)
        out[pid] = {
            "sent_ms": at,
            "first_reply_ms": first[0] - at if first else None,
            "first_reply_is_receipt": bool(first and is_desk(first[1])),
            "first_chief_reply_ms": first_chief[0] - at if first_chief else None,
        }
    return out


def leak_hits(texts, task):
    """Mentions of the reference answer in anything the agents said or ran:
    its PR number or its merge sha (short or long)."""
    # The PR number as a whole number (a millisecond time or byte count holding
    # its digits is no hit); the sha from its start (the full sha matches too).
    needles = [(str(task["reference_pr"]), rf"(?<!\d){task['reference_pr']}(?!\d)"),
               (task["reference"][:9], rf"(?<![0-9a-f]){task['reference'][:9]}")]
    hits = []
    for where, text in texts:
        for n, pattern in needles:
            if re.search(pattern, text):
                hits.append({"where": where, "needle": n})
    return hits


STUB = """#!/bin/sh
# team_eval stub: records the call and does nothing.
/usr/bin/python3 -I -c 'import json, sys, time; print(json.dumps({"tool": sys.argv[1], "args": sys.argv[2:], "ms": int(time.time() * 1000)}))' "{name}" "$@" >> "{log}"
echo "{name} is not available in this eval run: nothing was sent. Verify locally instead." >&2
exit 1
"""


def write_stubs(dir_, log):
    os.makedirs(dir_, exist_ok=True)
    for name in ("gh", "cmux-ci", "glaeda-gh"):
        p = os.path.join(dir_, name)
        with open(p, "w") as f:
            f.write(STUB.replace("{name}", name).replace("{log}", log))
        os.chmod(p, 0o755)


def checkout(repo, base, dest):
    """The task's tree at `base`, as a fresh repo with one commit: no history,
    so the merged answer is not in it."""
    os.makedirs(dest)
    arc = subprocess.Popen(["git", "-C", repo, "archive", "--format=tar", base], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", dest], stdin=arc.stdout, check=True)
    if arc.wait() != 0:
        raise SystemExit(f"git archive {base} failed")
    env = dict(os.environ, GIT_AUTHOR_NAME="eval", GIT_AUTHOR_EMAIL="eval@invalid",
               GIT_COMMITTER_NAME="eval", GIT_COMMITTER_EMAIL="eval@invalid")
    # The identity is the repo's own, so the agents' commits work too.
    for cmd in (["init", "-q", "-b", "main"], ["config", "user.name", "eval"], ["config", "user.email", "eval@invalid"],
                ["add", "-A"], ["commit", "-q", "-m", "base", "--no-verify"]):
        subprocess.run(["git", "-C", dest, *cmd], check=True, env=env)
    return subprocess.run(["git", "-C", dest, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()


def final_diff(dest, base_commit):
    """Everything the agents changed: commits and the working tree, new files too."""
    subprocess.run(["git", "-C", dest, "add", "-A"], check=False)
    return subprocess.run(["git", "-C", dest, "diff", "--cached", base_commit], capture_output=True, text=True).stdout


def lock_holders(path):
    """PIDs that hold `path` open (lsof), [] when none or no file."""
    if not os.path.exists(path):
        return []
    r = subprocess.run(["/usr/sbin/lsof", "-t", path], capture_output=True, text=True, timeout=20)
    return sorted({int(x) for x in r.stdout.split() if x.isdigit()})


def stop_acpmux(bins, home):
    """Stop the run's acpmux daemon and its router through their own shutdown
    paths, then check no process holds this home's locks; a holder left is
    this run's (the home is its alone): SIGTERM, then SIGKILL. As
    chief_driver.py's stop_acpmux. Returns the pids still left."""
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "ACPMUX_HOME": home,
           "ACPMUX_SOCKET": os.path.join(home, "acpmux.sock")}
    try:
        subprocess.run([os.path.join(bins, "acpmux"), "daemon", "shutdown", "--end-agents"], env=env,
                       timeout=30, capture_output=True)
    except (OSError, subprocess.TimeoutExpired):
        pass
    router = os.path.join(home, "router", "router.sock")
    if os.path.exists(router):
        try:
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(5)
                s.connect(router)
                s.sendall(b'{"op":"shutdown"}\n')
                s.recv(4096)
        except OSError:
            pass
    locks = [os.path.join(home, "daemon.lock"), os.path.join(home, "router", "router.lock")]
    left = []
    for step in ("wait", "term", "kill"):
        deadline = time.time() + (20 if step == "wait" else 5)
        while time.time() < deadline:
            try:
                left = sorted({p for lock in locks for p in lock_holders(lock)} - {os.getpid()})
            except (OSError, subprocess.TimeoutExpired):
                left = []
            if not left:
                break
            time.sleep(0.5)
        if not left or step == "kill":
            break
        for p in left:
            try:
                os.kill(p, signal.SIGTERM if step == "wait" else signal.SIGKILL)
            except ProcessLookupError:
                pass
    return left


def lossy_messages(events):
    """The conversation of an L run, in the Chief run's shape: every
    assistant text block is a message from the agent, every user line we
    sent is the person's. `events` are (arrival ms, stream-json event)."""
    msgs, arrivals = [], {}
    for at, e in events:
        if e.get("type") == "assistant":
            for block in (e.get("message") or {}).get("content") or []:
                if block.get("type") == "text" and block.get("text", "").strip():
                    m = {"id": f"l{len(msgs) + 1}", "seq": len(msgs) + 1, "author": CHIEF, "client_msg_id": "lossy",
                         "parts": [{"type": "text", "text": block["text"]}]}
                    msgs.append(m)
                    arrivals[m["id"]] = at
        elif e.get("type") == "eval.sent":
            m = {"id": f"l{len(msgs) + 1}", "seq": len(msgs) + 1, "author": "user_local", "client_msg_id": e["key"],
                 "parts": [{"type": "text", "text": e["text"]}]}
            msgs.append(m)
            arrivals[m["id"]] = at
    return msgs, arrivals


def lossy_cost(events):
    """Claude Code's own dollars: each `result` carries the process's running total."""
    return round(sum(rises([e["total_cost_usd"] for _, e in events
                            if e.get("type") == "result" and e.get("total_cost_usd") is not None])), 4)


def run_lossy(opts):
    import threading

    task = load_task(opts.tasks, opts.task)
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    brain = tempfile.mkdtemp(prefix="te.", dir="/tmp")
    repo_dir = os.path.abspath(opts.keep_repo) if opts.keep_repo else os.path.join(brain, "repo")
    stubs_log = os.path.join(out, "stubs.jsonl")
    shims = os.path.join(brain, "shims")
    write_stubs(shims, stubs_log)
    extra = dict(kv.split("=", 1) for kv in opts.env)
    info = {"task": task["id"], "arm": "L", "env": opts.env, "budget_usd": opts.budget_usd, "flags": [], "pid": os.getpid()}

    def log(msg):
        print(f"[team-eval {time.strftime('%H:%M:%S')}] {msg}", flush=True)

    proc = None

    def stop_claude():
        """Ends claude and everything it started (its own process group): TERM, then KILL."""
        if not proc:
            return
        for sig, wait in ((signal.SIGTERM, 20), (signal.SIGKILL, 5)):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                return
            try:
                proc.wait(timeout=wait)
            except subprocess.TimeoutExpired:
                continue
            # The leader is gone; give its group the same signal once more.
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                pass
            return

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))
    try:
        base_commit = checkout(opts.repo, task["base"], repo_dir)
        path = f"{shims}:{os.environ['HOME']}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env = {"HOME": os.environ["HOME"], "LANG": "en_US.UTF-8", "USER": os.environ.get("USER", "cmux"), "PATH": path}
        env.update({k: v for k, v in extra.items() if not k.startswith("OPTCHAT_")})
        claude = shutil.which("claude", path=path)
        if not claude:
            raise SystemExit("no claude on PATH")
        # The flags acpmux gives Claude Code (claude_stdio/mod.rs), and the Chief's model and effort.
        args = [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--replay-user-messages", "--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions",
                "--disallowedTools", "Task,Agent"]
        if extra.get("OPTCHAT_CHIEF_EFFORT"):
            args += ["--effort", extra["OPTCHAT_CHIEF_EFFORT"]]
        if extra.get("OPTCHAT_CHIEF_MODEL"):
            args += ["--model", extra["OPTCHAT_CHIEF_MODEL"]]
        proc = subprocess.Popen(args, cwd=repo_dir, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=open(os.path.join(out, "claude.stderr"), "w"), text=True, bufsize=1,
                                start_new_session=True)
        events = []
        lock = threading.Lock()

        def reader():
            for line in proc.stdout:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                with lock:
                    events.append((now_ms(), e))

        threading.Thread(target=reader, daemon=True).start()

        def send(pid, text):
            key = f"te-{pid}-{now_ms()}"
            line = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}
            proc.stdin.write(json.dumps(line) + "\n")
            proc.stdin.flush()
            with lock:
                events.append((now_ms(), {"type": "eval.sent", "key": key, "text": text}))

        meter = LiveMeter([os.path.join(os.environ["HOME"], ".claude"), extra.get("CLAUDE_CONFIG_DIR")])
        sent = {}
        t0 = now_ms()
        sent["brief"] = t0
        send("brief", task["brief"].replace("{repo}", repo_dir))
        log(f"up: task {task['id']} arm L repo {repo_dir}")
        pending = sorted(task["followups"], key=lambda f: f["at"])
        deadline = t0 + opts.max_minutes * 60000
        end = "deadline"
        while now_ms() < deadline:
            if proc.poll() is not None:
                end = f"claude exited {proc.returncode}"
                break
            if pending and now_ms() >= t0 + pending[0]["at"] * 1000:
                f = pending.pop(0)
                sent[f["id"]] = now_ms()
                send(f["id"], f["text"])
                log(f"sent {f['id']}")
            with lock:
                snap = list(events)
            cost = max(lossy_cost(snap), meter.usd())
            wrong = sorted(m for m in meter.models if not is_pinned_model(m))
            if wrong:
                end = "pin"
                info["flags"].append(f"stopped: {wrong} answered, not {PIN['model']}")
                break
            if cost > opts.budget_usd:
                end = "budget"
                info["flags"].append(f"stopped at ${cost:.2f}, over the ${opts.budget_usd:.0f} budget")
                break
            if not pending and snap:
                last_at, last = snap[-1]
                users = sum(1 for _, e in snap if e.get("type") == "eval.sent")
                results = sum(1 for _, e in snap if e.get("type") == "result")
                if last.get("type") == "result" and results >= 1 and now_ms() - last_at > opts.quiet_seconds * 1000:
                    end = "idle"
                    info["results_per_sent"] = f"{results}/{users}"
                    break
            time.sleep(0.5)
        info["end"] = end
        info["minutes"] = round((now_ms() - t0) / 60000, 1)
        # Stopped before the diff, so the diff is the tree the checks see.
        stop_claude()
        with lock:
            snap = list(events)
        msgs, arrivals = lossy_messages(snap)
        os.makedirs(os.path.join(out, "traces"), exist_ok=True)
        with open(os.path.join(out, "traces", "lossy.jsonl"), "w") as f:
            for at, e in snap:
                f.write(json.dumps({"at": at, **e}) + "\n")
        json.dump({"messages": msgs, "arrivals": arrivals}, open(os.path.join(out, "conversation.json"), "w"), indent=1)
        diff = final_diff(repo_dir, base_commit)
        open(os.path.join(out, "diff.patch"), "w").write(diff)
        stub_calls = [l for l in open(stubs_log)] if os.path.exists(stubs_log) else []
        texts = [("message", text_of(m)) for m in msgs] + [("diff", diff)] + [("stub", l) for l in stub_calls]
        texts += [("tool", json.dumps(b.get("input"))) for _, e in snap if e.get("type") == "assistant"
                  for b in (e.get("message") or {}).get("content") or [] if b.get("type") == "tool_use"]
        info.update({
            "sent": sent,
            "timeline": timeline(sent, msgs, arrivals),
            "cost_usd": {"turns": lossy_cost(snap), "subagents": 0, "compactor": 0, "all": lossy_cost(snap),
                         "live": round(meter.usd(), 4)},
            "followup_skew_s": followup_skew(sent, task),
            "pin": dict(pin_check(extra, meter.models), effort_flag=extra.get("OPTCHAT_CHIEF_EFFORT")),
            "turns": sum(1 for _, e in snap if e.get("type") == "result"),
            "compactions": sum(1 for _, e in snap if e.get("type") == "system" and e.get("subtype") == "compact_boundary"),
            "spawns": 0, "receipts": 0,
            "chief_messages": sum(1 for m in msgs if m.get("author") == CHIEF),
            "diff_lines": diff.count("\n"),
            "stub_calls": len(stub_calls),
            "leaks": leak_hits(texts, task),
        })
        if info["leaks"]:
            info["flags"].append("the reference answer was mentioned")
        log(f"done: {end} after {info['minutes']} min, ${max(info['cost_usd']['all'], info['cost_usd'].get('live') or 0)}, {info['turns']} turns, "
            f"diff {info['diff_lines']} lines, flags {info['flags']}")
    finally:
        # A second TERM (the step's own stop) must not cut the cleanup short.
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        stop_claude()
        left = []
        if proc:
            try:
                os.killpg(proc.pid, 0)
                left = [proc.pid]
            except (ProcessLookupError, PermissionError):
                pass
        alive = bool(left)
        info["acpmux_left"] = left
        print(f"[team-eval] acpmux cleanup: {'STILL HELD by claude ' + str(proc.pid) if alive else 'no process holds its locks'}"
              " (arm L runs no acpmux; this is its claude process)", flush=True)
        json.dump(info, open(os.path.join(out, "run.json"), "w"), indent=1)
        shutil.rmtree(brain, ignore_errors=True)


CAMPAIGN_ARMS = sorted(ARMS) + ["L"]
MIN_RUN_BUDGET = 5


class Ledger:
    """The eval's spend ledger: one JSON file, the cap fixed when it is made.
    `committed` is what finished attempts spent plus what running, crashed
    or unknown ones were allowed to spend. Every change re-reads the file
    under an exclusive file lock, so several campaign processes (a pilot and
    a full run, or a re-run while the first still lives) share one cap. A
    run that did not finish gets a new attempt (its own step key); the old
    attempt keeps its reservation, so a re-run never forgets money spent."""

    def __init__(self, path, cap):
        import threading
        self.path = os.path.expanduser(path)
        self.thread_lock = threading.Lock()
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with self._locked() as data:
            if data is None:
                if cap is None:
                    raise SystemExit("a new ledger needs --cap-usd")
                self.data = {"cap_usd": cap, "attempts": {}}
            elif cap is not None and abs(data["cap_usd"] - cap) > 1e-9:
                raise SystemExit(f"ledger {self.path} has cap ${data['cap_usd']}, not ${cap}; one cap per eval")

    def _locked(self):
        import contextlib
        import fcntl

        @contextlib.contextmanager
        def held():
            with self.thread_lock, open(self.path + ".lock", "a") as lk:
                fcntl.flock(lk, fcntl.LOCK_EX)
                try:
                    if os.path.exists(self.path):
                        with open(self.path) as f:
                            self.data = json.load(f)
                        yield self.data
                    else:
                        self.data = None
                        yield None
                    if self.data is not None:
                        tmp = self.path + ".tmp"
                        with open(tmp, "w") as f:
                            json.dump(self.data, f, indent=1)
                            f.flush()
                            os.fsync(f.fileno())
                        os.replace(tmp, self.path)
                finally:
                    fcntl.flock(lk, fcntl.LOCK_UN)
        return held()

    @staticmethod
    def _committed(data):
        return sum(a["spent"] if a["state"] in ("done", "void") else a["reserved"] for a in data["attempts"].values())

    def committed(self):
        with self._locked() as data:
            return self._committed(data)

    def cap(self):
        with self._locked() as data:
            return data["cap_usd"]

    def reserve(self, run, want, margin):
        """(attempt key, whole-dollar budget) for a new attempt of `run`,
        reserved with its margin; None when `run` already finished or the cap
        leaves less than MIN_RUN_BUDGET."""
        with self._locked() as data:
            mine = [k for k, a in data["attempts"].items() if a["run"] == run]
            if any(data["attempts"][k]["state"] == "done" for k in mine):
                return None
            budget = int(min(want, data["cap_usd"] - self._committed(data) - margin))
            if budget < MIN_RUN_BUDGET:
                return None
            key = f"{run}-a{len(mine) + 1}"
            data["attempts"][key] = {"run": run, "state": "running", "budget": budget, "reserved": budget + margin,
                                     "spent": None, "model": PIN["model"], "effort": PIN["effort"],
                                     "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
            return key, budget

    def void(self, key, step, failed):
        """An attempt that spent nothing (no agent started): counted as $0, and its run may run again."""
        with self._locked() as data:
            data["attempts"][key].update(state="void", spent=0, step=step, failed=failed)

    def settle(self, key, spent, step=None, pin=None, failed=None):
        """A finished attempt: its spend, or (None) unknown, which keeps the
        whole reservation; and what its pin check found."""
        with self._locked() as data:
            a = data["attempts"][key]
            a["step"] = step
            a["pin"] = pin
            a["failed"] = failed
            if spent is None:
                a["state"] = "unknown"
            else:
                a.update(state="done", spent=round(spent, 4))


def step_spend(stdout):
    """A step's real spend from its TEAM-EVAL line, or None."""
    for line in reversed(stdout.splitlines()):
        if line.startswith("TEAM-EVAL {"):
            c = json.loads(line[len("TEAM-EVAL "):]).get("cost_usd") or {}
            vals = [v for v in (c.get("all"), c.get("live")) if isinstance(v, (int, float))]
            return max(vals) if vals else None
    return None


def campaign(opts):
    from concurrent.futures import ThreadPoolExecutor

    ledger = Ledger(opts.ledger, opts.cap_usd)
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    runs = [(t, a, n) for n in range(1, opts.reps + 1) for t in opts.task for a in opts.arm]

    def one(run):
        task, arm, n = run
        got = ledger.reserve(f"team-eval-{opts.name}-{task}-{arm}-{n}", opts.run_budget, opts.margin)
        if got is None:
            return f"team-eval-{opts.name}-{task}-{arm}-{n}", f"not started: it already ran, or the ${ledger.cap():.0f} cap is reached"
        key, budget = got
        # Each attempt is its own step (key `<run>-a<n>`): a re-run never re-attaches
        # to an older one, whose reservation stays counted.
        cmd = ["cmux-ci", "run", "--class", "exclusive", "--script", "scripts/measure/team-eval.sh", "--ref", opts.ref,
               f"--arg=base_url={opts.base_url}", f"--arg=task={task}", f"--arg=arm={arm}", f"--arg=budget={budget}",
               f"--arg=minutes={opts.minutes}",
               "--artifact", ".build/team-eval/out.tgz", "--timeout", str(int(opts.minutes) * 60 + 3600), "--key", key]
        r = subprocess.run(cmd, capture_output=True, text=True)
        step = next((m.group(1) for m in re.finditer(r"cmux-ci: step (\S+) ", r.stderr)), None)
        os.makedirs(os.path.join(out, key), exist_ok=True)
        log = r.stdout
        if step and "TEAM-EVAL {" not in log:
            log += subprocess.run(["cmux-ci", "log", step], capture_output=True, text=True).stdout
        with open(os.path.join(out, key, "step.log"), "w") as f:
            f.write(log + "\n--- stderr\n" + r.stderr)
        spent = step_spend(log)
        if step:
            tgz = os.path.join(out, key, "out.tgz")
            if subprocess.run(["cmux-ci", "artifact", step, tgz], capture_output=True).returncode == 0:
                subprocess.run(["tar", "-xzf", tgz, "-C", os.path.join(out, key)], check=False)
        run_json = os.path.join(out, key, "out", "run.json")
        if spent is None and os.path.exists(run_json):
            with open(run_json) as f:
                spent = step_spend("TEAM-EVAL " + json.dumps(json.load(f)))
        line = next((json.loads(x[len("TEAM-EVAL "):]) for x in reversed(log.splitlines())
                     if x.startswith("TEAM-EVAL {")), {})
        pin = line.get("pin")
        if pin is None and os.path.exists(run_json):
            with open(run_json) as f:
                pin = json.load(f).get("pin")
        failed = line.get("failed", [f"step rc {r.returncode}, no TEAM-EVAL line"])
        if line.get("started") is False:
            # The step failed before any agent ran (route, build, install): $0, retryable.
            ledger.void(key, step, failed)
            return key, f"VOID before any agent ran: {failed}"
        ledger.settle(key, spent, step, pin, failed)
        return key, (f"{'ok' if not failed else 'FAILED ' + str(failed)}, "
                     f"spent {'unknown' if spent is None else f'${spent:.2f}'}")

    with ThreadPoolExecutor(max_workers=opts.parallel) as pool:
        for key, what in pool.map(one, runs):
            print(f"[team-eval campaign] {key}: {what}; committed ${ledger.committed():.2f} of ${ledger.cap():.0f}",
                  flush=True)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("campaign")
    c.add_argument("--name", required=True, help="the campaign's name, in every step key (pilot, full)")
    c.add_argument("--ref", required=True)
    c.add_argument("--base-url", required=True)
    c.add_argument("--task", nargs="+", required=True)
    c.add_argument("--arm", nargs="+", required=True, choices=CAMPAIGN_ARMS)
    c.add_argument("--reps", type=int, default=1)
    c.add_argument("--cap-usd", type=float, default=None, help="fixed when the ledger is made; 800 for this eval")
    c.add_argument("--ledger", default="~/.local/state/team-eval/ledger.json")
    c.add_argument("--run-budget", type=float, default=25)
    c.add_argument("--margin", type=float, default=12,
                   help="dollars a run may overshoot its budget by: about $3 per Opus response in flight when it "
                        "stops (the Chief and up to three subagents), read every 2 s")
    c.add_argument("--parallel", type=int, default=3)
    c.add_argument("--minutes", type=int, default=60)
    c.add_argument("--out", required=True)
    r = sub.add_parser("run")
    r.add_argument("--task", required=True)
    r.add_argument("--arm", required=True, choices=CAMPAIGN_ARMS)
    r.add_argument("--tasks", default=os.path.join(HERE, "team_eval_tasks.json"))
    r.add_argument("--bins", required=True)
    r.add_argument("--repo", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--env", action="append", default=[])
    r.add_argument("--budget-usd", type=float, default=40)
    r.add_argument("--max-minutes", type=float, default=60)
    r.add_argument("--quiet-seconds", type=float, default=90)
    r.add_argument("--keep-repo", default="", help="check the task out here and leave it (for checks after the run)")
    opts = ap.parse_args()
    if opts.cmd == "campaign":
        campaign(opts)
        return
    if opts.arm == "L":
        run_lossy(opts)
    else:
        run(opts)
    with open(os.path.join(opts.out, "run.json")) as f:
        pin = json.load(f).get("pin") or {"ok": False, "bad": ["no pin check (the run ended early)"]}
    if not pin["ok"]:
        print(f"[team-eval] FAILED the pin {PIN}: {pin['bad']}", flush=True)
        sys.exit(3)


def run(opts):
    task = load_task(opts.tasks, opts.task)
    arm = ARMS[opts.arm]
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    bins = os.path.abspath(opts.bins)
    # Short paths: the sockets must fit sun_path.
    brain = tempfile.mkdtemp(prefix="te.", dir="/tmp")
    sock = os.path.join(brain, "d", "cmux.sock")
    mux = os.path.join(brain, "mux")
    tools = os.path.join(mux, "optchat", "tools.sock")
    acpmux_home = os.path.join(brain, "acpmux")
    for d in ("d", "mux", "acpmux"):
        os.makedirs(os.path.join(brain, d), exist_ok=True)
    repo_dir = os.path.abspath(opts.keep_repo) if opts.keep_repo else os.path.join(brain, "repo")
    stubs_log = os.path.join(out, "stubs.jsonl")
    shims = os.path.join(brain, "shims")
    write_stubs(shims, stubs_log)
    pids = []
    info = {"task": task["id"], "arm": opts.arm, "brain": brain, "env": opts.env, "budget_usd": opts.budget_usd,
            "flags": [], "pid": os.getpid()}

    def log(msg):
        print(f"[team-eval {time.strftime('%H:%M:%S')}] {msg}", flush=True)

    def ask(req, timeout=30):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(timeout)
        s.connect(sock)
        s.sendall((json.dumps(dict(req, id=1)) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        s.close()
        res = json.loads(buf.decode())
        if not res.get("ok", True) and "data" not in res:
            raise RuntimeError(json.dumps(res)[:400])
        return res.get("data", res)

    traces = os.path.join(mux, "optchat", "traces")

    def trace_events():
        evs = []
        if os.path.isdir(traces):
            for name in sorted(os.listdir(traces)):
                for line in open(os.path.join(traces, name)):
                    try:
                        evs.append(json.loads(line))
                    except ValueError:
                        pass
        return evs

    stopped = []

    def stop_all():
        if stopped:
            return
        stopped.append(True)
        # A second TERM (the step's own stop) must not cut the cleanup short.
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        for p in reversed(pids):
            try:
                os.kill(p, signal.SIGTERM)
            except ProcessLookupError:
                pass
        left = stop_acpmux(bins, acpmux_home)
        info["acpmux_left"] = left
        deadline = time.time() + 20
        for p in pids:
            while True:
                try:
                    done, _ = os.waitpid(p, os.WNOHANG)
                except ChildProcessError:
                    break
                if done:
                    break
                if time.time() > deadline:
                    try:
                        os.kill(p, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        os.waitpid(p, 0)
                    except ChildProcessError:
                        pass
                    info["flags"].append(f"pid {p} needed SIGKILL")
                    break
                time.sleep(0.2)
        log(f"acpmux cleanup: {'no process holds its locks' if not left else 'STILL HELD by ' + str(left)}")

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))
    try:
        base_commit = checkout(opts.repo, task["base"], repo_dir)
        info["repo"] = repo_dir
        base_env = {"HOME": os.environ["HOME"], "LANG": "en_US.UTF-8", "USER": os.environ.get("USER", "cmux"),
                    "PATH": f"{shims}:{bins}:{os.environ['HOME']}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
        d = subprocess.Popen([os.path.join(bins, "cmux-tui"), "--headless", "--socket", sock],
                             stdout=open(os.path.join(out, "daemon.log"), "w"), stderr=subprocess.STDOUT,
                             env=dict(base_env, CMUX_TUI_STATE_DIR=os.path.join(brain, "d", "state"),
                                      CMUX_TUI_CHIEF_TOOLS_SOCKET=tools, ACPMUX_HOME=acpmux_home))
        pids.append(d.pid)
        for _ in range(200):
            if os.path.exists(sock):
                break
            time.sleep(0.1)
        # The arm's profile, before the host reads it at start.
        rule = os.path.join(brain, "rule.md")
        with open(rule, "w") as f:
            f.write(arm["rule"])
        edit = subprocess.run([os.path.join(bins, "cmux"), "--socket", sock, "chief", "edit", CHIEF,
                               "--tools", arm["tools"], "--self-edit", "", "--instructions-file", rule],
                              capture_output=True, text=True, env=base_env, timeout=30)
        info["profile_edit"] = {"rc": edit.returncode, "out": (edit.stdout + edit.stderr)[-400:]}
        if edit.returncode != 0:
            raise SystemExit(f"chief edit failed: {edit.stdout}{edit.stderr}")
        token = ask({"cmd": "conversation-agent-token", "participant": CHIEF})["token"]
        tok_file = os.path.join(brain, "agent-token")
        fd = os.open(tok_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, token.encode())
        os.close(fd)
        host_env = dict(base_env, MUX_HOME=mux, MUX_AGENT_TOKEN_FILE=tok_file, ACPMUX_HOME=acpmux_home,
                        ACPMUX_SOCKET=os.path.join(acpmux_home, "acpmux.sock"), ACPMUX_BIN=os.path.join(bins, "acpmux"),
                        MUX_HARNESS="claude", CMUX_DAEMON_SOCKET=sock, OPTCHAT_BACKUP_REMOTE="off",
                        OPTCHAT_DESK_GRACE_SECONDS=arm["grace"],
                        # Whole tool args in the trace: the pin reads each spawn's effort,
                        # the leak scan what the agents searched and fetched.
                        OPTCHAT_TRACE_FULL="1")
        host_env.update(dict(kv.split("=", 1) for kv in opts.env))
        h = subprocess.Popen([os.path.join(bins, "optchat-chief"), "host", "--daemon-socket", sock, "--mux-home", mux],
                             stdout=open(os.path.join(out, "host.log"), "w"), stderr=subprocess.STDOUT, env=host_env)
        pids.append(h.pid)
        for _ in range(600):
            if os.path.exists(tools) or h.poll() is not None:
                break
            time.sleep(0.1)
        if not os.path.exists(tools):
            raise SystemExit("the host served no tools socket; see host.log")
        conv = None
        for _ in range(300):
            cl = ask({"cmd": "conversation-list"})["conversations"]
            conv = next((c["id"] for c in cl if any(p["id"] == CHIEF for p in c.get("participants", []))), None)
            if conv:
                break
            time.sleep(0.2)
        if not conv:
            raise SystemExit("no Chief conversation")
        info["conversation"] = conv
        log(f"up: task {task['id']} arm {opts.arm} repo {repo_dir}")

        arrivals = {}

        def poll():
            snap = ask({"cmd": "conversation-snapshot", "conversation": conv, "tail": 500})
            t = now_ms()
            for m in snap.get("messages", []):
                arrivals.setdefault(m["id"], t)
            return snap.get("messages", [])

        def send(pid, text):
            key = f"te-{pid}-{now_ms()}"
            ask({"cmd": "conversation-op", "conversation": conv, "idempotency_key": key, "actor": "user_local",
                 "transaction": f"tx-{key}", "op": {"kind": "message.send", "client_msg_id": key,
                                                    "parts": [{"type": "text", "text": text}]}})

        meter = LiveMeter([brain, os.path.join(os.environ["HOME"], ".claude"),
                           dict(kv.split("=", 1) for kv in opts.env).get("CLAUDE_CONFIG_DIR")])
        last_meter = 0
        live = 0.0
        sent = {}
        t0 = now_ms()
        sent["brief"] = t0
        send("brief", task["brief"].replace("{repo}", repo_dir))
        pending = sorted(task["followups"], key=lambda f: f["at"])
        deadline = t0 + opts.max_minutes * 60000
        last_activity = now_ms()
        seen = 0
        end = "deadline"
        while now_ms() < deadline:
            msgs = poll()
            if pending and now_ms() >= t0 + pending[0]["at"] * 1000:
                f = pending.pop(0)
                sent[f["id"]] = now_ms()
                send(f["id"], f["text"])
                log(f"sent {f['id']}")
                last_activity = now_ms()
            ev = trace_events()
            if len(ev) + len(msgs) != seen:
                seen, last_activity = len(ev) + len(msgs), now_ms()
            if now_ms() - last_meter > 2000:
                live, last_meter = meter.usd(), now_ms()
            traced = trace_cost(ev)
            # Real spend: the transcripts' live total plus the compactor
            # (no transcript), or the trace's when that is higher.
            cost = max(traced["all"], live + traced["compactor"])
            early = pin_check(dict(kv.split("=", 1) for kv in opts.env), set(), ev)
            if early["bad"] and early["models"]:
                end = "pin"
                info["flags"].append(f"stopped: {early['bad']}, not {PIN}")
                break
            if cost > opts.budget_usd:
                end = "budget"
                info["flags"].append(f"stopped at ${cost:.2f}, over the ${opts.budget_usd:.0f} budget")
                break
            if not pending:
                starts = sum(1 for e in ev if e.get("ev") == "turn.start")
                ends = sum(1 for e in ev if e.get("ev") == "turn.end")
                spawns = {e.get("spawn") for e in ev if e.get("ev") == "spawn"}
                reported = {e.get("spawn") for e in ev if e.get("ev") == "spawn.report"}
                if starts == ends and not (spawns - reported) and now_ms() - last_activity > opts.quiet_seconds * 1000:
                    end = "idle"
                    break
            time.sleep(0.5)
        info["end"] = end
        info["minutes"] = round((now_ms() - t0) / 60000, 1)
        msgs = poll()
        json.dump({"messages": msgs, "arrivals": arrivals}, open(os.path.join(out, "conversation.json"), "w"), indent=1)
        # Stopped before the diff, so the diff is the tree the checks see.
        stop_all()
        ev = trace_events()
        shutil.copytree(traces, os.path.join(out, "traces"), dirs_exist_ok=True)
        diff = final_diff(repo_dir, base_commit)
        open(os.path.join(out, "diff.patch"), "w").write(diff)
        stub_calls = [l for l in open(stubs_log)] if os.path.exists(stubs_log) else []
        texts = [("message", text_of(m)) for m in msgs] + [("diff", diff)] + [("stub", l) for l in stub_calls]
        texts += [("tool", json.dumps(e)) for e in ev if e.get("ev") == "tool"]
        info.update({
            "sent": sent,
            "timeline": timeline(sent, msgs, arrivals),
            "cost_usd": dict(trace_cost(ev), live=round(meter.usd() + trace_cost(ev)["compactor"], 4)),
            "followup_skew_s": followup_skew(sent, task),
            "pin": pin_check(dict(kv.split("=", 1) for kv in opts.env), set(), ev),
            "transcript_models": sorted(meter.models),
            "turns": sum(1 for e in ev if e.get("ev") == "turn.end"),
            "spawns": sum(1 for e in ev if e.get("ev") == "spawn"),
            "receipts": sum(1 for m in msgs if is_desk(m)),
            "chief_messages": sum(1 for m in msgs if m.get("author") == CHIEF),
            "diff_lines": diff.count("\n"),
            "stub_calls": len(stub_calls),
            "leaks": leak_hits(texts, task),
        })
        if opts.arm == "A" and info["spawns"]:
            info["flags"].append("arm A spawned a subagent")
        if info["leaks"]:
            info["flags"].append("the reference answer was mentioned")
        log(f"done: {end} after {info['minutes']} min, ${max(info['cost_usd']['all'], info['cost_usd'].get('live') or 0)}, {info['turns']} turns, "
            f"{info['spawns']} spawns, diff {info['diff_lines']} lines, flags {info['flags']}")
    finally:
        # A second TERM (the step's own stop) must not cut the cleanup short.
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        # The evidence of a stopped run, before the brain dir goes.
        try:
            if info.get("conversation") and not os.path.exists(os.path.join(out, "conversation.json")):
                json.dump({"messages": poll(), "arrivals": arrivals}, open(os.path.join(out, "conversation.json"), "w"), indent=1)
        except Exception:
            pass
        stop_all()
        try:
            if os.path.isdir(traces) and not os.path.isdir(os.path.join(out, "traces")):
                shutil.copytree(traces, os.path.join(out, "traces"))
        except OSError:
            pass
        json.dump(info, open(os.path.join(out, "run.json"), "w"), indent=1)
        shutil.rmtree(brain, ignore_errors=True)


if __name__ == "__main__":
    main()
