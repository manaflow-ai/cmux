#!/usr/bin/env python3
"""Health of a real Chief, from its own memory and traces: no model, read-only, seconds.

usage: chief_health.py [--home OPTCHAT_DIR | --db MEMORY.sqlite3 --traces TRACES_DIR]
                       [--since 7d] [--json]

OPTCHAT_DIR is a Chief home's `optchat/` (default ~/.cmux/chief/default/optchat): it
holds memory.sqlite3 and traces/. The database is opened read-only. Each number is
given for the window (`--since`, default 7 days) and for all time.

What it measures (plans/cmux-next/chief-fast-iteration.md):

- Replies, as the person sees them: for each message the person typed, the time until
  Chief's first reply (a `talk` message, or a `send`/`reply` tool call). Short
  acknowledgements ("ok", "allow", "thanks") are left out: the person's rules say they
  get no reply.
  A reply within 15 minutes counts, so a burst answered together counts for each
  message. "acted": no reply, but Chief started or told a subagent for it.
- Dead-Chief pings: "hello?", "you there?" sent while an earlier message of the last
  30 minutes still had no reply.
- Turns cut by a server restart (the "The server restarted, cutting the turn" notice).
- Turn failures the person saw ("the turn failed (...)" notes in the memory).
- Turns (traces, `turn.end`): count, error and cancel shares, time p50/p95, first token
  p50/p95 (of turns that ended ok).
- Compactor refusals: memory lines that hold "I can't write this line ..." (the
  starts mirror optchat-core compact.rs REFUSAL_STARTS).
- "No such tool" calls: trace `tool` events whose error says the tool is not there.
- cmux usage errors: a tool call whose result starts "cmux: usage", by command shape.
- Spawns without a workspace: subagents whose spawn answer says "no cmux workspace".
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import sqlite3
import sys

REFUSAL_STARTS = (
    "i can't", "i cant ", "i cannot", "i can not", "i won't", "i will not",
    "i'm not able", "i am not able", "i'm unable", "i am unable", "i'm not going to",
    "i'm not writing", "i need to decline", "i must decline", "i'd rather not",
    "i don't think i can", "i apologize", "sorry", "please resend", "please tell me",
    "please provide", "could you", "can you",
)
RESTART_NOTICE = "The server restarted, cutting the turn"
ACK = re.compile(
    r"^\s*(ok(ay)?|k|kk|allow\.*|yes|yep|yeah|sure|sg|lgtm|thanks?|thx|ty|cool|nice|"
    r"great|good|go|do it|perfect|got it|👍|🙏)[\s.!]*$",
    re.I,
)
PING = re.compile(
    r"^\s*(hello|helo|hullo|hi|hey|yo|ping|are (you|u) there|(you|u) there|still there|"
    r"anyone there)?\s*\?+\s*$|^\s*(hello|helo|hullo)\s*$",
    re.I,
)
REPLY_TOOLS = ("mcp__optchat__send ", "mcp__optchat__reply ")
PING_WINDOW_S = 30 * 60
REPLY_WINDOW_S = 15 * 60
ACT_TOOLS = ("mcp__optchat__spawn ", "mcp__optchat__tell ")
FAILED_NOTE = "the turn failed"


def pct(values, p):
    """The p-quantile of `values` (nearest rank), None when empty."""
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return values[min(len(values) - 1, int(p * len(values)))]


def is_refusal(text):
    for line in text.splitlines():
        head = line.lstrip()[:40].replace("’", "'").replace("‘", "'").lower()
        if head.startswith(REFUSAL_STARTS):
            return True
    return False


def parse_since(text):
    m = re.fullmatch(r"(\d+)([hdw])", text)
    if not m:
        raise SystemExit(f"--since takes 12h, 7d or 2w, not {text!r}")
    n, unit = int(m.group(1)), m.group(2)
    return dt.timedelta(hours=n) if unit == "h" else dt.timedelta(days=n * (7 if unit == "w" else 1))


def when(date):
    return dt.datetime.fromisoformat(date)


def typed(msg):
    """A message the person typed: not a subagent report ("[a12] ...") or a notice."""
    return msg["kind"] == "user" and not msg["text"].startswith("[") and not msg["text"].startswith(RESTART_NOTICE)


def is_reply(msg):
    return msg["kind"] == "talk" or (msg["kind"] == "tool" and msg["text"].startswith(REPLY_TOOLS))


def replies(msgs, start):
    """Per typed message at or after `start`: (message, seconds to reply or None, acted).

    The reply is Chief's first reply after the message within REPLY_WINDOW_S, so a burst
    of messages answered together counts for each of them. `acted`: unanswered, but
    Chief started or told a subagent (spawn/tell) for it in that window."""
    out = []
    for i, m in enumerate(msgs):
        if not typed(m) or when(m["date"]) < start or ACK.match(m["text"]):
            continue
        t0 = when(m["date"])
        secs, acted = None, False
        for n in msgs[i + 1:]:
            gap = (when(n["date"]) - t0).total_seconds()
            if gap > REPLY_WINDOW_S:
                break
            if is_reply(n):
                secs = gap
                break
            if n["kind"] == "tool" and n["text"].startswith(ACT_TOOLS):
                acted = True
        out.append((m, secs, acted and secs is None))
    return out


def dead_pings(msgs, start):
    """Pings sent while a message of the last PING_WINDOW_S still had no reply."""
    count = 0
    waiting = None
    for m in msgs:
        if is_reply(m):
            waiting = None
        elif typed(m):
            t = when(m["date"])
            if PING.match(m["text"]) and waiting is not None and (t - waiting).total_seconds() <= PING_WINDOW_S:
                if t >= start:
                    count += 1
            elif waiting is None and not ACK.match(m["text"]):
                waiting = t
    return count


def usage_errors(msgs, start):
    """(cmux tool calls, usage errors, {command shape: count}) from tool/echo pairs."""
    calls, errors, shapes = 0, 0, {}
    for m, n in zip(msgs, msgs[1:]):
        if m["kind"] != "tool" or "cmux " not in m["text"] or when(m["date"]) < start:
            continue
        calls += 1
        if n["kind"] == "echo" and n["text"].lstrip().startswith("cmux: usage"):
            errors += 1
            cmd = re.search(r"cmux ((?:[a-z][\w-]*|<[^>]+>|\S+_\w+)(?: (?:--?[\w-]+|[a-z][\w-]*))?(?: (?:--?[\w-]+|[a-z][\w-]*))?)", m["text"])
            shape = re.sub(r"\b(tab|pane|ws|term|browser|screen)_[0-9a-f]+", r"\1_…", cmd.group(1)) if cmd else "?"
            shapes[shape] = shapes.get(shape, 0) + 1
    return calls, errors, shapes


def spawned(msgs, start):
    """(subagents started, of them without a workspace) from spawn answers."""
    total = without = 0
    for m, n in zip(msgs, msgs[1:]):
        if m["kind"] != "tool" or not m["text"].startswith("mcp__optchat__spawn") or when(m["date"]) < start:
            continue
        if n["kind"] != "echo":
            continue
        for line in re.findall(r"- a\d+: ([^\n]*)", n["text"]):
            total += 1
            if line.startswith("no cmux workspace"):
                without += 1
    return total, without


def trace_events(traces):
    for path in sorted(glob.glob(os.path.join(traces, "*.jsonl"))):
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue


def from_traces(traces, start_ms):
    turns, tools, no_tool, no_tool_names = [], 0, 0, {}
    for e in trace_events(traces):
        if (e.get("ts") or 0) < start_ms:
            continue
        ev = e.get("ev")
        if ev == "turn.end":
            turns.append(e)
        elif ev == "tool":
            tools += 1
            prefix = (e.get("error") or {}).get("prefix") or ""
            if "No such tool" in prefix:
                no_tool += 1
                name = e.get("name") or "?"
                no_tool_names[name] = no_tool_names.get(name, 0) + 1
    statuses = {}
    for t in turns:
        statuses[t.get("status") or "?"] = statuses.get(t.get("status") or "?", 0) + 1
    ok = [t for t in turns if t.get("status") == "ok"]
    return {
        "turns": len(turns),
        "turn_status": statuses,
        "turn_error_rate": statuses.get("error", 0) / len(turns) if turns else None,
        # Before the host traced `stopped` (Oct 27), a turn the Chief ended itself with
        # stop/sleep after its reply was traced `cancelled` too: older traces count both.
        "turn_cancelled_rate": statuses.get("cancelled", 0) / len(turns) if turns else None,
        "turn_stopped_by_chief_rate": statuses.get("stopped", 0) / len(turns) if turns else None,
        "turn_s_p50": _s(pct([t.get("ms") for t in ok], 0.5)),
        "turn_s_p95": _s(pct([t.get("ms") for t in ok], 0.95)),
        "first_token_s_p50": _s(pct([t.get("ttft_ms") for t in ok], 0.5)),
        "first_token_s_p95": _s(pct([t.get("ttft_ms") for t in ok], 0.95)),
        "tool_calls": tools,
        "no_such_tool": no_tool,
        "no_such_tool_names": no_tool_names,
    }


def _s(ms):
    return None if ms is None else round(ms / 1000, 1)


def measure(db, traces, start):
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    msgs = [
        {"id": i, "kind": k, "date": d, "text": t}
        for i, k, d, t in conn.execute("SELECT id, kind, date, text FROM messages ORDER BY id")
    ]
    day = start.date().isoformat()
    nodes = conn.execute("SELECT text FROM nodes WHERE day >= ?", (day,)).fetchall()
    conn.close()
    rep = replies(msgs, start)
    secs = [s for _, s, _ in rep if s is not None]
    asked = len(rep)
    cmux_calls, cmux_errors, shapes = usage_errors(msgs, start)
    started, no_ws = spawned(msgs, start)
    refusals = sum(1 for (t,) in nodes if is_refusal(t))
    out = {
        "since": start.isoformat(timespec="seconds"),
        "typed_messages": asked,
        "reply_s_p50": pct(secs, 0.5) and round(pct(secs, 0.5), 1),
        "reply_s_p90": pct(secs, 0.9) and round(pct(secs, 0.9), 1),
        "replied_within_10s_rate": sum(1 for s in secs if s <= 10) / asked if asked else None,
        "replied_after_60s_rate": sum(1 for s in secs if s > 60) / asked if asked else None,
        "unanswered": asked - len(secs),
        "unanswered_rate": (asked - len(secs)) / asked if asked else None,
        "acted_without_reply": sum(1 for _, _, acted in rep if acted),
        "failed_turns_seen": sum(1 for m in msgs if m["kind"] == "note" and m["text"].startswith(FAILED_NOTE) and when(m["date"]) >= start),
        "dead_chief_pings": dead_pings(msgs, start),
        "restart_cut_turns": sum(1 for m in msgs if m["kind"] == "user" and m["text"].startswith(RESTART_NOTICE) and when(m["date"]) >= start),
        "memory_lines": len(nodes),
        "compactor_refusal_lines": refusals,
        "compactor_refusal_rate": refusals / len(nodes) if nodes else None,
        "cmux_calls": cmux_calls,
        "cmux_usage_errors": cmux_errors,
        "cmux_usage_error_rate": cmux_errors / cmux_calls if cmux_calls else None,
        "cmux_usage_error_shapes": dict(sorted(shapes.items(), key=lambda kv: -kv[1])),
        "subagents_started": started,
        "subagents_without_workspace": no_ws,
    }
    start_ms = int(start.timestamp() * 1000)
    out.update(from_traces(traces, start_ms) if traces and os.path.isdir(traces) else {})
    return out


ROWS = [
    ("typed_messages", "messages the person typed (no acks)", "n"),
    ("reply_s_p50", "time to first reply, p50 (s)", "f"),
    ("reply_s_p90", "time to first reply, p90 (s)", "f"),
    ("replied_within_10s_rate", "replied within 10 s", "%"),
    ("replied_after_60s_rate", "replied after more than 60 s", "%"),
    ("unanswered_rate", "no reply within 15 min", "%"),
    ("acted_without_reply", "  of them acted on (spawn/tell), no message", "n"),
    ("dead_chief_pings", '"hello?" pings while waiting', "n"),
    ("restart_cut_turns", "turns cut by a server restart", "n"),
    ("turns", "turns (traces)", "n"),
    ("failed_turns_seen", "turn failures the person saw", "n"),
    ("turn_error_rate", "turns that ended in an error", "%"),
    ("turn_cancelled_rate", "turns cancelled (before Oct 27: and self-stopped)", "%"),
    ("turn_stopped_by_chief_rate", "turns the Chief ended itself (stop/sleep)", "%"),
    ("turn_s_p50", "turn time p50 (s)", "f"),
    ("turn_s_p95", "turn time p95 (s)", "f"),
    ("first_token_s_p50", "first token p50 (s)", "f"),
    ("first_token_s_p95", "first token p95 (s)", "f"),
    ("compactor_refusal_lines", "compactor refusal lines", "n"),
    ("compactor_refusal_rate", "compactor refusal rate", "%"),
    ("no_such_tool", '"No such tool" calls', "n"),
    ("tool_calls", "tool calls (traces)", "n"),
    ("cmux_usage_errors", "cmux usage errors", "n"),
    ("cmux_usage_error_rate", "cmux usage error rate", "%"),
    ("subagents_started", "subagents started", "n"),
    ("subagents_without_workspace", "subagents without a workspace", "n"),
]


def fmt(value, kind):
    if value is None:
        return "-"
    if kind == "%":
        return f"{100 * value:.2f}%"
    if kind == "f":
        return f"{value:.1f}"
    return str(value)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--home", default=os.path.expanduser("~/.cmux/chief/default/optchat"))
    ap.add_argument("--db")
    ap.add_argument("--traces")
    ap.add_argument("--since", default="7d")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--now", help="the end of the window, ISO time (tests); default now")
    a = ap.parse_args(argv)
    db = a.db or os.path.join(a.home, "memory.sqlite3")
    traces = a.traces or os.path.join(a.home, "traces")
    if not os.path.exists(db):
        raise SystemExit(f"no memory database at {db}")
    now = dt.datetime.fromisoformat(a.now) if a.now else dt.datetime.now(dt.timezone.utc).astimezone()
    window = measure(db, traces, now - parse_since(a.since))
    whole = measure(db, traces, dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc))
    if a.json:
        json.dump({"window": window, "all": whole}, sys.stdout, indent=1)
        print()
        return 0
    print(f"Chief health: {db}")
    print(f"{'':42s} {'last ' + a.since:>12s} {'all time':>12s}")
    for key, label, kind in ROWS:
        print(f"{label:42s} {fmt(window.get(key), kind):>12s} {fmt(whole.get(key), kind):>12s}")
    for title, key in (("cmux usage errors by command", "cmux_usage_error_shapes"),
                       ('"No such tool" by name', "no_such_tool_names")):
        shown = whole.get(key) or {}
        if shown:
            print(f"{title} (all time): " + ", ".join(f"{k} {v}" for k, v in list(shown.items())[:6]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
