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
  A-steer  A, and a follow-up sent while a turn runs interrupts it: the
      eval presses the owner's stop (`cmux chief stop`, chief.stop, as
      Ctrl+C in the chat does), waits for the turn to end, then posts the
      message, so a fresh turn answers it at once. (Every Chief arm already
      steers a message into the running turn at its next tool boundary,
      but the turn answers only at its end; the steer that stops the
      current step, acpmux's `steerNow`, is not reachable from the Chief.)
  L   Lossy heads-down: no Chief. One plain Claude Code session (stream-json,
      as acpmux runs Claude Code) in the task repo, with its own
      auto-compaction; a message sent while it works is read at its next
      tool boundary (its replayed echo) and answered at the turn's end.

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
run.json `tokens` has its input, output and cache tokens (the transcripts'
plus the compactor's), the budget that counts now; `cost_usd` is the same
usage at list prices.

Stalls (run.json `stall`, every arm): for each message the eval posts, when
it was sent, when the agent started on it and its first reply. Started is
the Chief's read cursor reaching the message (the brain moves it when a
turn takes the message or Claude Code reads it as a steer); arm L's is
Claude Code's replayed echo of the line (`--replay-user-messages`, the
uuid we sent). A message never started waited to the run's end.
`queued_over_10s` counts those that waited more than 10 s. A message is
`busy` when it was sent mid-turn (trace turn.start over turn.end; arm L:
its last event was not a `result`) with BUSY_LANES or more subagents
running (trace subagent.start without subagent.done; arms A and L can
start none, so theirs are 0).

Every agent's Claude Code runs with ANTHROPIC_LOG=debug, which prints each
response's real headers: run.json `ratelimit` has the last and the lowest
weekly headroom of the anthropic-ratelimit-unified-7d-* headers (arm L
from claude's stdout, the Chief arms from acpmux's `[non-json stdout]`
records in its session logs). Each new reading is also printed at once as
`TEAM-EVAL-RATELIMIT {json}` (on --live-fd too: the step's stdout), arm L
as claude's stdout is read, the Chief arms by following acpmux's session
logs with kqueue (AcpmuxFollower). See headroom_probe.py. Caveats: a
compactor session acpmux has purged by the run's end is missing from the
summary (the live lines have what was seen); debug logging may slow the
agents a little (an e2e run compares).

  team_eval.py campaign --ref SHA --base-url URL --task ID... --arm ARM...
      [--reps 1] [--cap-usd USD] [--ledger FILE] [--run-budget 25]
      [--margin 12] [--parallel 3] [--max-concurrent 4]
      [--headroom-cmd CMD] [--min-headroom 0.25] [--headroom-window 20]
      [--headroom-max-age 30] [--headroom-sleep 180] --out DIR
runs every task x arm x rep as a fleet step (scripts/measure/team-eval.sh),
at most --max-concurrent at once (the pool has max(--parallel,
--max-concurrent) threads). The ledger (default
~/.local/state/team-eval/ledger.json) holds each run's tokens and dollars
and what each running one may still spend; the campaign prints the tokens
first. The budget is account usage now, so a dollar cap is optional
(--cap-usd, none by default). With one, fixed when the ledger is made, a
run starts only when spent + reserved + its budget + margin stays under
the cap; its budget is cut to fit, and none starts below $5. A run whose spend is unknown (no
TEAM-EVAL line) counts its whole reservation. The margin covers what is
still in flight when a run stops (about $3 per Opus response: the Chief
and its subagents). Re-running a campaign skips finished runs and starts a
new attempt (its own step key) of the others; an older attempt keeps its
reservation until it settles. A run that failed (`ok` false: a pin
failure, processes left) is recorded as done with its spend and `failed`.

Before each step starts (checked again once its worker is free, right
before `cmux-ci run`), the weekly headroom must be at least
--min-headroom: the lowest of the last --headroom-window readings in the
ledger that are under --headroom-max-age minutes old. A running step's
readings reach the window as it runs: `cmux-ci run` streams the step's log
on stdout (the worker ships it every 2 s, the client copies it every 2 s),
and the campaign reads each TEAM-EVAL-RATELIMIT line as it comes; the
step's summary adds any it missed (once per request id). With no recent
reading, --headroom-cmd (default headroom_probe.py --base-url BASE_URL:
one real `claude -p` on the cheapest model through the steps' route) is
run once for one; it prints the remaining weekly fraction (0..1). Below
the minimum, or with no reading (the command failed or printed something
else), no new step starts (fail closed) and running ones go on: the
campaign logs it and checks again every --headroom-sleep seconds. A low
reading holds the pause until it is --headroom-max-age old (no probe can
outvote it: the probe may land on another account), so a shorter max age
resumes sooner. A reading covers only the upstream account its request
was routed to, so the window covers only the accounts the pool rotated
through. Reading ages compare a worker's clock (or the host's, for a
probe) with this host's: clock skew between them shifts them.
--headroom-cmd '' turns the check off (one warning).
"""
import argparse
import json
import os
import re
import select
import shlex
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
# A with the owner's stop on every follow-up sent mid-turn (the docstring).
ARMS["A-steer"] = dict(ARMS["A"], interrupt=True)
# Subagents running at once that make a mid-turn message `busy`.
BUSY_LANES = 5


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
from headroom_probe import RatelimitParser, ratelimit_readings, reading_headroom  # noqa: E402

TOKEN_KEYS = ("input", "output", "cache_write", "cache_read")


def usage_tokens(usage):
    """One API response's tokens, in the trace's names."""
    return {"input": usage.get("input_tokens") or 0, "output": usage.get("output_tokens") or 0,
            "cache_write": usage.get("cache_creation_input_tokens") or 0,
            "cache_read": usage.get("cache_read_input_tokens") or 0}


def sum_tokens(parts):
    """The sum of token dicts, with `total`."""
    out = {k: sum((p or {}).get(k) or 0 for p in parts) for k in TOKEN_KEYS}
    out["total"] = sum(out.values())
    return out


def node_tokens(events):
    """The compactor's tokens: its nodes' usage (it writes no transcript)."""
    return sum_tokens([e.get("usage") for e in events if e.get("ev") == "node"])


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
        self.tokens_by_id = {}
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

    def tokens(self):
        """The transcripts' tokens so far, read as `usd` reads them."""
        self.usd()
        return sum_tokens(self.tokens_by_id.values())

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
            mid = msg.get("id") or f"{path}:{len(self.by_id)}"
            self.by_id[mid] = usage_usd(msg.get("model"), msg["usage"])
            self.tokens_by_id[mid] = usage_tokens(msg["usage"])
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


def chief_state(events, at):
    """(mid-turn, subagents running) of a Chief run at `at` ms, from its
    trace: a turn.start not yet ended, and subagent.start (or .resume) ids
    not yet done."""
    starts = ends = 0
    running = set()
    for e in events:
        if (e.get("ts") or 0) > at:
            continue
        if e.get("ev") == "turn.start":
            starts += 1
        elif e.get("ev") == "turn.end":
            ends += 1
        elif e.get("ev") in ("subagent.start", "subagent.resume"):
            running.add(e.get("id"))
        elif e.get("ev") == "subagent.done":
            running.discard(e.get("id"))
    return starts > ends, len(running)


def lossy_state(events, at):
    """(mid-turn, 0) of an L run at `at` ms: something was sent and its last
    event before `at` is not a `result`. It can start no subagent (Task and
    Agent are disallowed)."""
    before = [e for t, e in events if t < at]
    sent = any(e.get("type") == "eval.sent" for e in before)
    return bool(sent and before[-1].get("type") != "result"), 0


def cursor_starts(keys, messages, cursor_log):
    """When the Chief started on each prompt: the first poll at which its read
    cursor (`cursor_log`: (ms, seq) as polled) reached the prompt's seq.
    `keys` maps a prompt id to its client_msg_id."""
    seq = {m.get("client_msg_id"): m.get("seq") for m in messages}
    out = {}
    for pid, key in keys.items():
        s = seq.get(key)
        out[pid] = next((t for t, c in cursor_log if s is not None and c is not None and c >= s), None)
    return out


def replay_starts(uuids, events):
    """When arm L's Claude Code read each prompt: its replayed echo of our
    line (the uuid we sent). `uuids` maps a prompt id to that uuid."""
    seen = {}
    for t, e in events:
        if e.get("type") == "user" and e.get("uuid"):
            seen.setdefault(e["uuid"], t)
    return {pid: seen.get(u) for pid, u in uuids.items()}


def p50(xs):
    xs = sorted(xs)
    if not xs:
        return None
    mid = len(xs) // 2
    return xs[mid] if len(xs) % 2 else (xs[mid - 1] + xs[mid]) / 2


def attributed_replies(sent, starts, messages, arrivals):
    """Each prompt's first reply that can only be its own: the first Chief
    message (a desk receipt too) after the agent started on the prompt and
    after the reply credited to the prompt before it, so an answer to an
    earlier prompt is never a later one's. {pid: (ms after sent, or None;
    unattributable)}: unattributable when the start was never seen, so no
    reply can be tied to it."""
    chief = sorted((arrivals.get(m["id"], 0), m["seq"] if m.get("seq") is not None else -1) for m in messages
                   if m.get("author") == CHIEF and text_of(m).strip())
    # The floor is the last credited message as (arrival, seq): two messages seen
    # in the same poll share an arrival, and the later one is still free.
    out, floor = {}, None
    for pid, at in sorted(sent.items(), key=lambda kv: kv[1]):
        st = starts.get(pid)
        if st is None:
            out[pid] = (None, True)
            continue
        hit = next((ts for ts in chief if ts[0] >= max(at, st) and (floor is None or ts > floor)), None)
        out[pid] = (hit[0] - at if hit is not None else None, False)
        if hit is not None:
            floor = hit
    return out


def stall(sent, starts, replies, states, end_ms):
    """Each prompt's wait and first reply, and their summary. `starts` maps a
    prompt id to the ms the agent started on it (None: never seen),
    `replies` is attributed_replies(), `states` maps it to (mid-turn,
    subagents running) when it was sent (None: unknown)."""
    per = {}
    for pid, at in sorted(sent.items(), key=lambda kv: kv[1]):
        st = starts.get(pid)
        mid, lanes = states.get(pid, (None, None))
        reply, unattributable = replies.get(pid, (None, True))
        per[pid] = {"sent_ms": at, "started_ms": st, "wait_ms": st - at if st is not None else None,
                    "waited_to_end_ms": end_ms - at if st is None else None,
                    "first_reply_ms": reply, "reply_unattributable": unattributable,
                    "mid_turn": mid, "lanes": lanes,
                    "busy": None if mid is None or (mid and lanes is None) else bool(mid and lanes >= BUSY_LANES)}
    return {"messages": per, "summary": stall_summary(per.values())}


def stall_summary(msgs):
    """First-reply p50 and max (s), how many waited over 10 s before the agent
    started on them (one never started waited to the run's end), and the
    first replies of the `busy` ones apart. Pools any runs' messages."""
    msgs = list(msgs)

    def over(m):
        if m.get("wait_ms") is not None:
            return m["wait_ms"] > 10000
        if m.get("waited_to_end_ms") is not None:
            return m["waited_to_end_ms"] > 10000
        return None

    def replies(ms):
        r = [m["first_reply_ms"] / 1000 for m in ms if m.get("first_reply_ms") is not None]
        return {"first_reply_p50_s": p50(r), "first_reply_max_s": max(r) if r else None,
                "no_reply": sum(1 for m in ms if m.get("first_reply_ms") is None and not m.get("reply_unattributable")),
                "reply_unattributable": sum(1 for m in ms if m.get("reply_unattributable"))}

    known = [over(m) for m in msgs if over(m) is not None]
    busy = [m for m in msgs if m.get("busy")]
    return dict(replies(msgs), messages=len(msgs),
                queued_over_10s={"count": sum(known), "of": len(known),
                                 "rate": round(sum(known) / len(known), 3) if known else None},
                never_started=sum(1 for m in msgs if m.get("started_ms") is None),
                busy=dict(replies(busy), messages=len(busy), lanes_at=BUSY_LANES,
                          unknown=sum(1 for m in msgs if m.get("busy") is None)))


def ratelimit_summary(readings):
    """A run's unified rate-limit readings: how many, the last (with its
    headroom) and the lowest headroom. Each covers one upstream account."""
    rs = sorted((r for r in readings if reading_headroom(r) is not None), key=lambda r: r["at"])
    if not rs:
        return {"count": 0, "last": None, "min_headroom": None, "readings": []}
    return {"count": len(rs), "last": dict(rs[-1], headroom=round(reading_headroom(rs[-1]), 4)),
            "min_headroom": round(min(reading_headroom(r) for r in rs), 4),
            # The campaign's window holds READINGS; a step's newest are enough.
            "readings": rs[-Ledger.READINGS:]}


def wait_for_change(paths, timeout, still=None):
    """Blocks until one of `paths` (files or directories) is written or
    extended, or `timeout` seconds pass (kqueue; without it, or with nothing
    to watch, one sleep of `timeout`). `still()` is checked once the watch
    is in place and the wait skipped when it is false, so a change between
    the caller's own check and the watch is never missed."""
    timeout = max(0.0, timeout)
    if not hasattr(select, "kqueue") or not paths:
        if still is None or still():
            time.sleep(timeout)
        return
    fds, kq = [], select.kqueue()
    try:
        for p in paths:
            try:
                fds.append(os.open(p, os.O_RDONLY))
            except OSError:
                continue
        if not fds:
            if still is None or still():
                time.sleep(timeout)
            return
        kq.control([select.kevent(fd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                  select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND) for fd in fds], 0)
        if still is not None and not still():
            return
        kq.control(None, 1, timeout)
    finally:
        for fd in fds:
            os.close(fd)
        kq.close()


class LiveReadings:
    """Prints each new real reading at once, as one flushed line
    `TEAM-EVAL-RATELIMIT {json}` on stdout and on `fd` (the step's own
    stdout, which cmux-ci streams to the campaign while the step runs;
    team-eval.sh keeps the driver's stdout in driver.log). Once per request
    id."""

    def __init__(self, fd=None):
        import threading
        self.fd, self.seen, self.lock = fd, set(), threading.Lock()

    def emit(self, readings):
        for r in readings:
            h = reading_headroom(r)
            if h is None:
                continue
            with self.lock:
                if r.get("request_id") and r["request_id"] in self.seen:
                    continue
                self.seen.add(r.get("request_id"))
                line = "TEAM-EVAL-RATELIMIT " + json.dumps(dict(r, headroom=round(h, 4))) + "\n"
                sys.stdout.write(line)
                sys.stdout.flush()
                if self.fd is not None:
                    try:
                        os.write(self.fd, line.encode())
                    except OSError:
                        pass


class AcpmuxFollower:
    """Follows acpmux's session logs as they grow (kqueue: a vnode watch on
    the home, `sessions/`, each session's `events/` and each log file),
    reads only the bytes past each file's offset, and passes the readings
    in their `[non-json stdout]` records to `on_readings`. No timer: the
    thread blocks in kevent until a watched file or directory changes, or
    `stop` wakes it (a last read first). Without kqueue (not macOS) it
    follows nothing and says so."""

    def __init__(self, acpmux_home, on_readings, log=print):
        import threading
        self.home, self.on, self.log = acpmux_home, on_readings, log
        self.watched, self.offsets, self.partial, self.parsers = {}, {}, {}, {}
        self.wake_r, self.wake_w = os.pipe()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        if not hasattr(select, "kqueue"):
            self.log("no kqueue here: live rate-limit readings are off (the run's summary still has them)")
            return self
        self.kq = select.kqueue()
        self.kq.control([select.kevent(self.wake_r, select.KQ_FILTER_READ, select.KQ_EV_ADD)], 0)
        self.thread.start()
        return self

    def stop(self):
        if self.wake_w < 0:
            return
        if self.thread.is_alive():
            os.write(self.wake_w, b"x")
            self.thread.join(10)
        if self.thread.is_alive():
            # Still in a pass: it may yet read wake_r, so the pipe stays open.
            self.log("the acpmux log follower did not stop in 10 s; its pipe stays open")
            return
        for fd in (self.wake_r, self.wake_w):
            try:
                os.close(fd)
            except OSError:
                pass
        self.wake_r = self.wake_w = -1

    def _watch(self, path):
        if path in self.watched:
            return
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError:
            return
        self.watched[path] = fd
        self.kq.control([select.kevent(fd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                       select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)], 0)

    def _unwatch(self, path):
        fd = self.watched.pop(path, None)
        if fd is not None:
            os.close(fd)  # closing the fd drops its kevent

    def _scan(self):
        """Watches what is new, then reads every log's new bytes."""
        self._watch(self.home)
        root = os.path.join(self.home, "sessions")
        if not os.path.isdir(root):
            return
        self._watch(root)
        for sid in sorted(os.listdir(root)):
            events = os.path.join(root, sid, "events")
            self._watch(os.path.join(root, sid))
            if not os.path.isdir(events):
                continue
            self._watch(events)
            names = sorted(n for n in os.listdir(events) if n.endswith(".ndjson"))
            for name in names:
                path = os.path.join(events, name)
                # Only the newest log of a session grows: one fd per session. An
                # older one is read once more (its last bytes), then let go.
                if name == names[-1]:
                    self._watch(path)
                else:
                    self._unwatch(path)
                self._read(sid, path)

    def _read(self, sid, path):
        try:
            with open(path, "rb") as f:
                f.seek(self.offsets.get(path, 0))
                chunk = f.read()
        except OSError:
            return
        self.offsets[path] = self.offsets.get(path, 0) + len(chunk)
        data = self.partial.pop(path, b"") + chunk
        whole, _, rest = data.rpartition(b"\n")
        if rest:
            self.partial[path] = rest
        parser = self.parsers.setdefault(sid, RatelimitParser())
        got = []
        for raw in whole.splitlines():
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if isinstance(e, dict) and e.get("kind") == "stderr":
                got += parser.feed((e.get("msg") or {}).get("text") or "", e.get("at"))
        if got:
            self.on(got)

    def _scan_safely(self):
        # A race (a file gone between listdir and open) or a failing callback
        # costs this pass only, never the thread.
        try:
            self._scan()
        except Exception as e:  # noqa: BLE001
            self.log(f"following acpmux's session logs: {type(e).__name__}: {e}; going on")

    def _run(self):
        try:
            while True:
                self._scan_safely()
                try:
                    evs = self.kq.control(None, 64, None)
                except InterruptedError:
                    continue
                except OSError as e:
                    self.log(f"following acpmux's session logs stopped: kevent failed: {e}")
                    break
                if any(e.ident == self.wake_r for e in evs):
                    self._scan_safely()
                    break
        finally:
            for fd in self.watched.values():
                try:
                    os.close(fd)
                except OSError:
                    pass
            self.kq.close()


def acpmux_ratelimit(acpmux_home):
    """The readings in acpmux's session logs: a harness's stdout lines that are
    not JSON (ANTHROPIC_LOG=debug's) are `stderr` records `[non-json
    stdout] ...`, in order, per session."""
    out = []
    root = os.path.join(acpmux_home, "sessions")
    for sid in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        events = os.path.join(root, sid, "events")
        lines = []
        for name in sorted(os.listdir(events)) if os.path.isdir(events) else []:
            with open(os.path.join(events, name), errors="replace") as fh:
                for raw in fh:
                    try:
                        e = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(e, dict) and e.get("kind") == "stderr":
                        lines.append((e.get("at"), (e.get("msg") or {}).get("text") or ""))
        out += ratelimit_readings(lines)
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
        # Each response's real headers on stdout (the rate-limit readings).
        env["ANTHROPIC_LOG"] = "debug"
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
                                stderr=open(os.path.join(out, "claude.stderr"), "w"), encoding="utf-8",
                                errors="replace", bufsize=1,
                                start_new_session=True)
        events = []
        debug_lines = []
        lock = threading.Lock()
        live_rl = LiveReadings(opts.live_fd)
        live_parser = RatelimitParser()

        def reader():
            for line in proc.stdout:
                try:
                    e = json.loads(line)
                except ValueError:
                    # ANTHROPIC_LOG's lines: they hold the response headers.
                    at, text = now_ms(), line.rstrip("\n")
                    debug_lines.append((at, text))
                    live_rl.emit(live_parser.feed(text, at))
                    continue
                if not isinstance(e, dict):
                    continue
                with lock:
                    events.append((now_ms(), e))

        threading.Thread(target=reader, daemon=True).start()

        uuids = {}

        def send(pid, text):
            import uuid
            key = f"te-{pid}-{now_ms()}"
            # Claude Code echoes the line with this uuid when it reads it (as acpmux relies on).
            uuids[pid] = str(uuid.uuid4())
            line = {"type": "user", "uuid": uuids[pid],
                    "message": {"role": "user", "content": [{"type": "text", "text": text}]}}
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
        end_ms = now_ms()
        # Stopped before the diff, so the diff is the tree the checks see.
        stop_claude()
        with lock:
            snap = list(events)
        msgs, arrivals = lossy_messages(snap)
        readings = ratelimit_readings(debug_lines)
        with open(os.path.join(out, "ratelimit.jsonl"), "w") as f:
            for r in readings:
                f.write(json.dumps(r) + "\n")
        tl = timeline(sent, msgs, arrivals)
        starts = replay_starts(uuids, snap)
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
            "timeline": tl,
            "stall": stall(sent, starts, attributed_replies(sent, starts, msgs, arrivals),
                           {p: lossy_state(snap, at) for p, at in sent.items()}, end_ms),
            "tokens": meter.tokens(),
            "ratelimit": ratelimit_summary(readings),
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
        log(f"done: {end} after {info['minutes']} min, {info['tokens']['total']} tokens "
            f"(${max(info['cost_usd']['all'], info['cost_usd'].get('live') or 0)}), {info['turns']} turns, "
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
    """The eval's spend ledger: one JSON file, the dollar cap (or none) fixed
    when it is made. `committed` is what finished attempts spent plus what
    running, crashed or unknown ones were allowed to spend; `tokens` what
    finished ones used. It also keeps the last READINGS rate-limit readings
    of every campaign that shares it (Headroom). Every change re-reads the file
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
                self.data = {"cap_usd": cap, "attempts": {}}
            elif cap is not None and (data["cap_usd"] is None or abs(data["cap_usd"] - cap) > 1e-9):
                raise SystemExit(f"ledger {self.path} has cap {data['cap_usd']}, not ${cap}; one cap per eval")

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
        """The dollar cap, or None."""
        with self._locked() as data:
            return data["cap_usd"]

    def tokens(self):
        """The tokens of every settled attempt that reported them."""
        with self._locked() as data:
            return sum_tokens([a.get("tokens") for a in data["attempts"].values()])

    READINGS = 200

    def add_readings(self, readings):
        """Adds readings, once per request id (a step's live line and its
        TEAM-EVAL summary may carry the same one), and keeps the newest
        READINGS by their own time (`at`), not by when they were added: a
        step's summary re-adds old readings at its end."""
        with self._locked() as data:
            have = {r.get("request_id") for r in data.get("ratelimit", []) if r.get("request_id")}
            new = []
            for r in readings:
                if r.get("request_id") and r["request_id"] in have:
                    continue
                have.add(r.get("request_id"))
                new.append(r)
            kept = sorted(data.get("ratelimit", []) + new, key=lambda r: r.get("at") or 0)
            data["ratelimit"] = kept[-self.READINGS:]

    def readings(self):
        with self._locked() as data:
            return list(data.get("ratelimit", []))

    def reserve(self, run, want, margin):
        """(attempt key, whole-dollar budget) for a new attempt of `run`,
        reserved with its margin; None when `run` already finished or the cap
        leaves less than MIN_RUN_BUDGET. With no cap the budget is `want`."""
        with self._locked() as data:
            mine = [k for k, a in data["attempts"].items() if a["run"] == run]
            if any(data["attempts"][k]["state"] == "done" for k in mine):
                return None
            cap = data["cap_usd"]
            budget = int(want if cap is None else min(want, cap - self._committed(data) - margin))
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

    def settle(self, key, spent, step=None, pin=None, failed=None, tokens=None):
        """A finished attempt: its spend, or (None) unknown, which keeps the
        whole reservation; its tokens (None: unknown); and what its pin
        check found."""
        with self._locked() as data:
            a = data["attempts"][key]
            a["step"] = step
            a["pin"] = pin
            a["failed"] = failed
            a["tokens"] = tokens
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


def step_line(stdout):
    """A step's TEAM-EVAL line as a dict, {} when it has none."""
    return next((json.loads(x[len("TEAM-EVAL "):]) for x in reversed(stdout.splitlines())
                 if x.startswith("TEAM-EVAL {")), {})


class Headroom:
    """The campaign's weekly-headroom gate (the module docstring): `wait`
    returns once the lowest headroom of the recent readings in the ledger
    is at least `minimum`, probing with `cmd` when none is recent, and
    otherwise sleeps `sleep_s` between checks. One check at a time, so
    threads waiting to start share one probe. `cmd` empty: no gate."""

    def __init__(self, ledger, cmd, minimum, window, max_age_s, sleep_s, log, sleep=time.sleep, clock=time.time):
        import threading
        self.ledger, self.cmd, self.minimum = ledger, cmd, minimum
        self.window, self.max_age_s, self.sleep_s = window, max_age_s, sleep_s
        self.log, self.sleep, self.clock = log, sleep, clock
        self.lock = threading.Lock()
        if not cmd:
            log("WARNING: no --headroom-cmd: steps start whatever the pool's weekly headroom")

    def probe(self):
        """(headroom, why): what `cmd` printed, or None when it failed or
        printed no fraction 0..1."""
        try:
            r = subprocess.run(self.cmd, shell=True, capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.TimeoutExpired) as e:
            return None, f"--headroom-cmd failed: {e}"
        out = r.stdout.strip()
        if r.returncode != 0:
            return None, f"--headroom-cmd exit {r.returncode}: {(r.stderr.strip() or out)[-200:]}"
        try:
            x = float(out.splitlines()[-1])
        except (ValueError, IndexError):
            x = None
        if x is None or not 0 <= x <= 1:
            return None, f"--headroom-cmd printed {out[-80:]!r}, not a fraction 0..1"
        return x, "probe"

    def recent(self):
        """The readings the gate reads: those under max-age, then the newest
        `window` of them by their own time."""
        since = (self.clock() - self.max_age_s) * 1000
        fresh = sorted((r for r in self.ledger.readings()
                        if (r.get("at") or 0) >= since and reading_headroom(r) is not None),
                       key=lambda r: r.get("at") or 0)
        return fresh[-self.window:]

    def current(self):
        """(lowest recent headroom or None, why)."""
        fresh = self.recent()
        why = None
        if not fresh:
            x, why = self.probe()
            if x is None:
                return None, f"no reading in {self.max_age_s / 60:.0f} min and {why}"
            r = {"at": int(self.clock() * 1000), "source": "probe", "headroom": x}
            self.ledger.add_readings([r])
            fresh = [r]
        return (min(reading_headroom(r) for r in fresh),
                f"lowest of {len(fresh)} reading(s) in {self.max_age_s / 60:.0f} min{', probed' if why else ''}")

    def note(self, key, reading):
        """A step's live reading: logs when it takes the lowest recent
        headroom under the line (new steps then wait; running ones go on)."""
        h = reading_headroom(reading)
        if not self.cmd or h is None or h >= self.minimum:
            return
        fresh = [reading_headroom(r) for r in self.recent()]
        if not fresh:
            # Too old (a late log, clock skew) or out of the window: it gates nothing.
            self.log(f"live reading from {key}: headroom {h:.2f}, but it is not among the recent readings; "
                     "the gate does not count it")
        elif min(fresh) == h:
            self.log(f"live reading from {key}: headroom {h:.2f} is under {self.minimum}: no new step starts; "
                     "running steps go on")

    def ok(self):
        """One check now (a probe when no reading is recent): may a step start?"""
        if not self.cmd:
            return True
        with self.lock:
            h, why = self.current()
            return h is not None and h >= self.minimum

    def wait(self):
        if not self.cmd:
            return None
        with self.lock:
            paused = None
            while True:
                h, why = self.current()
                if h is not None and h >= self.minimum:
                    if paused is not None:
                        self.log(f"headroom {h:.2f} ({why}) is at least {self.minimum}: resuming after "
                                 f"{(self.clock() - paused) / 60:.1f} min")
                    return h
                if h is None:
                    self.log(f"headroom unknown ({why}): failing closed, no new step; next check in {self.sleep_s:.0f} s")
                else:
                    self.log(f"headroom {h:.2f} ({why}) is under {self.minimum}: pausing new steps; "
                             f"next check in {self.sleep_s:.0f} s")
                paused = self.clock() if paused is None else paused
                self.sleep(self.sleep_s)


def default_headroom_cmd(base_url):
    """headroom_probe.py through the steps' route, so it reads their pool's accounts."""
    return " ".join(map(shlex.quote, (sys.executable, os.path.join(HERE, "headroom_probe.py"), "--base-url", base_url)))


def positive(text):
    """A whole number of at least 1."""
    try:
        n = int(text)
    except ValueError:
        n = 0
    if n < 1:
        raise argparse.ArgumentTypeError(f"{text!r} is not a whole number of at least 1")
    return n


def fraction(text):
    """A number from 0 to 1."""
    try:
        x = float(text)
    except ValueError:
        x = -1
    if not 0 <= x <= 1:
        raise argparse.ArgumentTypeError(f"{text!r} is not a fraction from 0 to 1")
    return x


def above_zero(text):
    """A number over 0."""
    try:
        x = float(text)
    except ValueError:
        x = 0
    if not x > 0:
        raise argparse.ArgumentTypeError(f"{text!r} is not a number over 0")
    return x


def full_sha(ref):
    """cmux-ci takes only a full SHA and refuses anything else before a step
    exists, so reject it here, before any reservation."""
    if not re.fullmatch(r"[0-9a-f]{40}", ref):
        raise argparse.ArgumentTypeError(f"{ref!r} is not a lowercase 40-character commit SHA")
    return ref


def campaign(opts):
    import queue
    from concurrent.futures import ThreadPoolExecutor

    if opts.worker:
        # A targeted step waits for its worker with no limit, so a name the
        # controller does not know, or a machine it still lists but has not
        # heard from lately, would hang the campaign on its reservation.
        from datetime import datetime, timedelta, timezone
        known = json.loads(subprocess.run(["cmux-ci", "workers"], capture_output=True, text=True, check=True).stdout)
        recent = datetime.now(timezone.utc) - timedelta(minutes=10)

        def live(w):
            seen = known.get(w, {}).get("last_seen", "")
            # Go drops trailing zeros from the fraction; Python 3.9 parses only 3 or 6 digits.
            seen = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], seen.replace("Z", "+00:00"))
            return bool(seen) and datetime.fromisoformat(seen) > recent

        down = [w for w in opts.worker if not live(w)]
        if down:
            sys.exit(f"team-eval campaign: not live controller workers (unknown, or unseen for 10 minutes): {down}")
    import threading
    ledger = Ledger(opts.ledger, opts.cap_usd)
    say = lambda msg: print(f"[team-eval campaign {time.strftime('%H:%M:%S')}] {msg}", flush=True)
    if opts.headroom_cmd is None:
        opts.headroom_cmd = default_headroom_cmd(opts.base_url)
    headroom = Headroom(ledger, opts.headroom_cmd, opts.min_headroom, opts.headroom_window,
                        opts.headroom_max_age * 60, opts.headroom_sleep, say)
    # Steps in flight, whatever the pool and the free workers allow.
    in_flight = threading.BoundedSemaphore(opts.max_concurrent)
    # A step must run where --base-url resolves (a tailnet host, not an AWS Mac):
    # with --worker each step takes a free one of these, so no two share one.
    free = queue.Queue()
    for w in opts.worker:
        free.put(w)
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    runs = [(t, a, n) for n in range(1, opts.reps + 1) for t in opts.task for a in opts.arm]

    def run_streaming(cmd, key):
        """cmux-ci run, its stdout (the step's log, streamed as the step runs)
        read line by line as it comes: each TEAM-EVAL-RATELIMIT reading goes
        into the ledger's window at once. Returns what subprocess.run would."""
        import types
        # A stray byte in a step's log is replaced, never an error that stops the reading.
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8", errors="replace",
                             bufsize=1)
        err = []
        drain = threading.Thread(target=lambda: err.append(p.stderr.read()), daemon=True)
        drain.start()
        lines = []
        for line in p.stdout:
            lines.append(line)
            if line.startswith("TEAM-EVAL-RATELIMIT {"):
                # Nothing here may stop the reading: the step runs on, and its
                # worker must not go back before it ends.
                try:
                    reading = json.loads(line[len("TEAM-EVAL-RATELIMIT "):])
                    reading.update(source=key, arrived=int(time.time() * 1000))
                    ledger.add_readings([reading])
                    headroom.note(key, reading)
                except Exception as e:  # noqa: BLE001
                    say(f"{key}: a live reading was not taken ({type(e).__name__}: {e}): {line.strip()[:200]}")
        p.wait()
        drain.join()
        p.stdout.close()
        p.stderr.close()
        return types.SimpleNamespace(stdout="".join(lines), stderr="".join(err), returncode=p.returncode)

    def one(run):
        with in_flight:
            return start(run)

    def start(run):
        task, arm, n = run
        headroom.wait()
        got = ledger.reserve(f"team-eval-{opts.name}-{task}-{arm}-{n}", opts.run_budget, opts.margin)
        if got is None:
            return f"team-eval-{opts.name}-{task}-{arm}-{n}", "not started: it already ran, or the dollar cap is reached"
        key, budget = got
        # Each attempt is its own step (key `<run>-a<n>`): a re-run never re-attaches
        # to an older one, whose reservation stays counted.
        cmd = ["cmux-ci", "run", "--class", "exclusive", "--script", "scripts/measure/team-eval.sh", "--ref", opts.ref,
               f"--arg=base_url={opts.base_url}", f"--arg=task={task}", f"--arg=arm={arm}", f"--arg=budget={budget}",
               f"--arg=minutes={opts.minutes}",
               "--artifact", ".build/team-eval/out.tgz", "--timeout", str(int(opts.minutes) * 60 + 3600), "--key", key]
        cmd += [f"--label={label}" for label in opts.label]
        while True:
            worker = free.get() if opts.worker else None
            # Again with the worker in hand: the wait for it may have been long,
            # and a live reading may have taken the headroom under the line.
            try:
                ok = headroom.ok()
            except BaseException:
                if worker:
                    free.put(worker)
                raise
            if ok:
                break
            if worker:
                free.put(worker)
            headroom.wait()
        try:
            r = run_streaming(cmd + (["--target-worker", worker] if worker else []), key)
        except Exception as e:  # noqa: BLE001
            # The step may have started: its spend is unknown, so it keeps its reservation.
            ledger.settle(key, None, None, None, [f"campaign: cmux-ci run failed: {type(e).__name__}: {e}"])
            return key, f"FAILED: cmux-ci run failed ({type(e).__name__}: {e}), spent unknown"
        finally:
            if worker:
                free.put(worker)
        try:
            return finish(key, r)
        except Exception as e:  # noqa: BLE001
            # A truncated TEAM-EVAL line or a corrupt run.json: the attempt failed and
            # its spend is unknown (the whole reservation stays); the campaign goes on.
            ledger.settle(key, None, None, None, [f"campaign: the step's output did not read: {type(e).__name__}: {e}"])
            return key, f"FAILED: its output did not read ({type(e).__name__}: {e}), spent unknown"

    def finish(key, r):
        """Reads a finished step's output and settles its attempt."""
        step = next((m.group(1) for m in re.finditer(r"cmux-ci: step (\S+) ", r.stderr)), None)
        os.makedirs(os.path.join(out, key), exist_ok=True)
        log = r.stdout
        if step and "TEAM-EVAL {" not in log:
            log += subprocess.run(["cmux-ci", "log", step], capture_output=True, encoding="utf-8",
                                  errors="replace").stdout
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
        line = step_line(log)
        if os.path.exists(run_json):
            with open(run_json) as f:
                packed = json.load(f)
            for k in ("pin", "tokens", "ratelimit"):
                if line.get(k) is None:
                    line[k] = packed.get(k)
        pin = line.get("pin")
        # The step's last response's reading joins the window the gate reads.
        # The step's readings join the window the gate reads (the live ones are
        # in already: once per request id), the last too when it has no id.
        rl = line.get("ratelimit") or {}
        ledger.add_readings([dict(x, source=key) for x in (rl.get("readings") or []) + [rl.get("last")] if x])
        failed = line.get("failed", [f"step rc {r.returncode}, no TEAM-EVAL line"])
        # 409: the key already names a step that may have run, so keep the reservation.
        refused = re.search(r"cmux-ci: controller HTTP 4(?!09)\d\d: .*", r.stderr)
        if not step and refused:
            # The controller refused the step (allowlist, bad args): it never existed, $0, retryable.
            ledger.void(key, None, [refused.group(0)])
            return key, f"VOID, refused: {refused.group(0)}"
        if line.get("started") is False:
            # The step failed before any agent ran (route, build, install): $0, retryable.
            ledger.void(key, step, failed)
            return key, f"VOID before any agent ran: {failed}"
        tokens = line.get("tokens")
        ledger.settle(key, spent, step, pin, failed, tokens)
        return key, (f"{'ok' if not failed else 'FAILED ' + str(failed)}, "
                     f"{'tokens unknown' if not tokens else str(tokens.get('total')) + ' tokens'}, "
                     f"spent {'unknown' if spent is None else f'${spent:.2f}'}")

    with ThreadPoolExecutor(max_workers=max(opts.parallel, opts.max_concurrent)) as pool:
        for key, what in pool.map(one, runs):
            cap = ledger.cap()
            print(f"[team-eval campaign] {key}: {what}; used {ledger.tokens()['total']} tokens, committed "
                  f"${ledger.committed():.2f}{'' if cap is None else f' of ${cap:.0f}'}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("campaign")
    c.add_argument("--name", required=True, help="the campaign's name, in every step key (pilot, full)")
    c.add_argument("--ref", required=True, type=full_sha, help="the full 40-character commit the steps check out")
    c.add_argument("--base-url", required=True)
    c.add_argument("--task", nargs="+", required=True)
    c.add_argument("--arm", nargs="+", required=True, choices=CAMPAIGN_ARMS)
    c.add_argument("--reps", type=int, default=1)
    c.add_argument("--cap-usd", type=float, default=None,
                   help="an optional dollar cap, fixed when the ledger is made (default none: the budget is account usage)")
    c.add_argument("--ledger", default="~/.local/state/team-eval/ledger.json")
    c.add_argument("--run-budget", type=float, default=25)
    c.add_argument("--margin", type=float, default=12,
                   help="dollars a run may overshoot its budget by: about $3 per Opus response in flight when it "
                        "stops (the Chief and up to three subagents), read every 2 s")
    c.add_argument("--parallel", type=int, default=3)
    c.add_argument("--worker", nargs="+", default=[],
                   help="controller workers to run on (names from cmux-ci workers) that can reach --base-url; "
                        "each step takes a free one")
    c.add_argument("--label", action="append", default=[],
                   help="a worker label each step also needs, on top of the script's own (repeatable); "
                        "cmux20-bench, for example, runs only steps labeled bench")
    c.add_argument("--max-concurrent", type=positive, default=4,
                   help="steps in flight at most, even when more workers are free")
    c.add_argument("--headroom-cmd", default=None,
                   help="prints the pool's remaining weekly fraction (0..1), run when no reading is recent "
                        "(default: headroom_probe.py --base-url BASE_URL); '' turns the headroom check off")
    c.add_argument("--min-headroom", type=fraction, default=0.25, help="start no step while the headroom is below this")
    c.add_argument("--headroom-window", type=positive, default=20, help="the last N readings the check reads")
    c.add_argument("--headroom-max-age", type=above_zero, default=30, help="minutes a reading counts")
    c.add_argument("--headroom-sleep", type=above_zero, default=180, help="seconds between checks while paused")
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
    r.add_argument("--live-fd", type=int, default=None,
                   help="also write each TEAM-EVAL-RATELIMIT line to this open fd (the step's stdout)")
    opts = ap.parse_args()
    if opts.cmd == "run" and opts.live_fd is not None:
        # An fd that is not open now could later be a pipe of the run's own
        # (arm L's claude stdin): never write lines there.
        try:
            os.fstat(opts.live_fd)
        except OSError:
            print(f"[team-eval] --live-fd {opts.live_fd} is not open: live readings go to stdout only", flush=True)
            opts.live_fd = None
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

    # The readings in acpmux's session logs, printed as they come.
    follower = AcpmuxFollower(acpmux_home, LiveReadings(opts.live_fd).emit, log)
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
        follower.stop()
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
                        OPTCHAT_TRACE_FULL="1",
                        # Each response's real headers on Claude Code's stdout, which
                        # acpmux logs as `[non-json stdout]` (the rate-limit readings).
                        ANTHROPIC_LOG="debug")
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
        follower.start()
        log(f"up: task {task['id']} arm {opts.arm} repo {repo_dir}")

        arrivals = {}
        # The Chief's read cursor as polled: (ms, seq) at each change.
        cursor_log = []
        keys = {}

        def poll():
            snap = ask({"cmd": "conversation-snapshot", "conversation": conv, "tail": 500})
            t = now_ms()
            for m in snap.get("messages", []):
                arrivals.setdefault(m["id"], t)
            c = ((snap.get("conversation") or {}).get("read_cursors") or {}).get(CHIEF)
            if not cursor_log or cursor_log[-1][1] != c:
                cursor_log.append((t, c))
            return snap.get("messages", [])

        def send(pid, text):
            key = f"te-{pid}-{now_ms()}"
            keys[pid] = key
            ask({"cmd": "conversation-op", "conversation": conv, "idempotency_key": key, "actor": "user_local",
                 "transaction": f"tx-{key}", "op": {"kind": "message.send", "client_msg_id": key,
                                                    "parts": [{"type": "text", "text": text}]}})

        def interrupt_turn():
            """Arm A-steer: the owner's stop on the running turn, as Ctrl+C in
            the chat does; then the turn's end (up to 30 s), so the message
            starts a fresh turn and is not read by the stopped one."""
            at = now_ms()
            try:
                r = subprocess.run([os.path.join(bins, "cmux"), "--socket", sock, "chief", "stop"],
                                   capture_output=True, text=True, env=base_env, timeout=30)
                rc, said = r.returncode, (r.stdout + r.stderr)[-200:]
            except (OSError, subprocess.TimeoutExpired) as e:
                rc, said = None, str(e)[-200:]
            running = lambda: chief_state(trace_events(), now_ms())[0]
            while now_ms() - at < 30000 and running():
                poll()  # replies and the cursor keep their times meanwhile
                # Until the trace changes (the turn.end), at most to the deadline; the
                # watch is in place before the turn is checked again, so no end is missed.
                wait_for_change([traces] + [os.path.join(traces, n) for n in os.listdir(traces)]
                                if os.path.isdir(traces) else [], (30000 - (now_ms() - at)) / 1000, running)
            ended = not chief_state(trace_events(), now_ms())[0]
            log(f"stopped the running turn: rc {rc}, {'ended' if ended else 'STILL RUNNING'} "
                f"after {(now_ms() - at) / 1000:.1f} s")
            if not ended or rc != 0:
                info["flags"].append(f"the stop before a follow-up did not end the turn (rc {rc}): {said}")
            return {"rc": rc, "out": said, "ended": ended, "ms": now_ms() - at}

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
            ev = trace_events()
            if pending and now_ms() >= t0 + pending[0]["at"] * 1000:
                f = pending.pop(0)
                sent[f["id"]] = now_ms()
                if arm.get("interrupt") and chief_state(ev, now_ms())[0]:
                    info.setdefault("interrupts", []).append(dict(interrupt_turn(), prompt=f["id"]))
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
        end_ms = now_ms()
        msgs = poll()
        json.dump({"messages": msgs, "arrivals": arrivals}, open(os.path.join(out, "conversation.json"), "w"), indent=1)
        # Stopped before the diff, so the diff is the tree the checks see.
        stop_all()
        ev = trace_events()
        shutil.copytree(traces, os.path.join(out, "traces"), dirs_exist_ok=True)
        readings = acpmux_ratelimit(acpmux_home)
        with open(os.path.join(out, "ratelimit.jsonl"), "w") as f:
            for r in readings:
                f.write(json.dumps(r) + "\n")
        tl = timeline(sent, msgs, arrivals)
        starts = cursor_starts(keys, msgs, cursor_log)
        diff = final_diff(repo_dir, base_commit)
        open(os.path.join(out, "diff.patch"), "w").write(diff)
        stub_calls = [l for l in open(stubs_log)] if os.path.exists(stubs_log) else []
        texts = [("message", text_of(m)) for m in msgs] + [("diff", diff)] + [("stub", l) for l in stub_calls]
        texts += [("tool", json.dumps(e)) for e in ev if e.get("ev") == "tool"]
        info.update({
            "sent": sent,
            "timeline": tl,
            "stall": stall(sent, starts, attributed_replies(sent, starts, msgs, arrivals),
                           {p: chief_state(ev, at) for p, at in sent.items()}, end_ms),
            "tokens": dict(sum_tokens([meter.tokens(), node_tokens(ev)]), compactor=node_tokens(ev)),
            "ratelimit": ratelimit_summary(readings),
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
        if not arm["tools"] and info["spawns"]:
            info["flags"].append(f"arm {opts.arm} spawned a subagent")
        if info["leaks"]:
            info["flags"].append("the reference answer was mentioned")
        log(f"done: {end} after {info['minutes']} min, {info['tokens']['total']} tokens "
            f"(${max(info['cost_usd']['all'], info['cost_usd'].get('live') or 0)}), {info['turns']} turns, "
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
