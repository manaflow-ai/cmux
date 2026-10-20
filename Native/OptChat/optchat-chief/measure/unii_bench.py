#!/usr/bin/env python3
"""Unii baseline vs the Chief harness: one multi-turn chat, same model, same route.

"Unii baseline" is UniiChat's request shape (github.com/VictorTaelin/UniiChat,
Anthropic.ts + Memory.view + Server.ts turn): its own prompt.txt as the cached
system prompt, its ~9 small tools, the <chat> view cut into 4-line blocks with
one mark at the last whole block, the new message marked, top-level
cache_control, adaptive thinking, one direct streamed Messages API request
from an already-running server (no process start).

"The Chief harness" is our turn path as optchat-chief runs it: a fresh Claude
Code process per turn (`claude -p`, stream-json), the Chief's preset system
prompt, the turn isolation args (host.rs turn_isolation_args), Claude Code's own
cache marks off (DISABLE_PROMPT_CACHING=1) and ours on the input blocks: the
frozen view's end, the previous request's end, this request's end
(prompt.rs input_layout). With --sticky it also sends X-Subrouter-Session, as
acpmux now does for a Chief turn (subrouter_session.rs).

Both get the same synthetic view (VIEW_KB of `id+n|text` lines) and the same
turns; each turn appends the previous reply and a new user message. Numbers:
time to first token, turn time, input / cache read / cache write / output
tokens, cache hit (read / (input + read + write)), cost at list prices.

usage:
  unii_bench.py --harness unii --unii-src DIR [--model M] [--turns N] [--sticky KEY]
  unii_bench.py --harness chief --chief-system FILE [--model M] [--turns N] [--sticky KEY]
Route: ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_CUSTOM_HEADERS from
the environment (the team sr2 gateway signs requests itself). Prints one JSON
line per turn ("UNII-BENCH {...}") and a summary line. Cheap, network-bound: a
build host or a Mac with the route; it never builds anything.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

# list prices per million tokens (input, cache write 1h, cache write 5m, cache read, output)
PRICES = {
    "claude-opus-5-5": (5.0, 10.0, 6.25, 0.5, 25.0),
    "claude-sonnet-5": (3.0, 6.0, 3.75, 0.3, 15.0),
    "claude-haiku-5-5": (1.0, 2.0, 1.25, 0.1, 5.0),
}

TURNS = [
    "What did we decide about the nightly runners, in one sentence?",
    "Which agent owns the sidebar scroll lag? One line.",
    "Summarize the open asks for me in one short sentence.",
    "Is the Cloud Chief paired yet? One line.",
    "Name one thing still blocked on CI. One line.",
    "Say ok.",
]

ASK = "Answer in one short sentence, from the chat above, with no tool calls."


def view_lines(kb):
    """A deterministic view like a real Chief view: zoom lines, one per message
    near the end, wider summaries at the start."""
    words = ("agent fleet nightly sidebar cache cloud chief pairing markdown tab "
             "browser omnibar crash test push branch build mini queue report").split()
    out, i, n = [], 0, 256
    while sum(len(x) for x in out) < kb * 1024:
        k = len(out)
        text = " ".join(words[(k * 7 + j * 3) % len(words)] for j in range(60))
        out.append(f"{i}+{n}|user asked about {text}; a{k % 90} working, pushed {k:07x}.\n")
        i += n
        if k % 6 == 5 and n > 1:
            n //= 2
    return out


def usage_of(u):
    return {
        "input": u.get("input_tokens", 0) or 0,
        "cache_read": u.get("cache_read_input_tokens", 0) or 0,
        "cache_write": u.get("cache_creation_input_tokens", 0) or 0,
        "output": u.get("output_tokens", 0) or 0,
    }


def cost(model, u, ttl_1h):
    p = PRICES.get(model, PRICES["claude-opus-5-5"])
    w = p[1] if ttl_1h else p[2]
    return (u["input"] * p[0] + u["cache_write"] * w + u["cache_read"] * p[3] + u["output"] * p[4]) / 1e6


def headers(sticky):
    h = {"content-type": "application/json", "anthropic-version": "2023-06-01"}
    tok = os.environ.get("ANTHROPIC_AUTH_TOKEN") or os.environ.get("ANTHROPIC_API_KEY") or "x"
    h["authorization"] = "Bearer " + tok
    h["x-api-key"] = tok
    for line in (os.environ.get("ANTHROPIC_CUSTOM_HEADERS") or "").splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            h[k.strip()] = v.strip()
    if sticky:
        h["X-Subrouter-Session"] = sticky
    return h


# Unii baseline -------------------------------------------------------------

def unii_tools():
    """UniiChat's master tool set by name and field shape (zoom, date, spawn,
    tell, computer, shell, read, write, edit); short descriptions of our own."""
    s, i = {"type": "string"}, {"type": "integer"}

    def t(name, info, props, req):
        return {"name": name, "description": info, "eager_input_streaming": True,
                "input_schema": {"type": "object", "properties": props, "required": req}}
    dev = {"device": s}
    edit = {"type": "object", "properties": {"path": s, "old": s, "new": s, "all": {"type": "boolean"}},
            "required": ["path", "old", "new"]}
    return [
        t("zoom", "Open view line id+n into the two lines under it; n=1 gives the message whole.",
          {"id": {"type": ["integer", "string"]}, "n": i, "at": i}, ["id"]),
        t("date", "The date and time of message id.", {"id": i}, ["id"]),
        t("spawn", "Start one subagent per task, in parallel; reports come back as messages.",
          {"tasks": {"type": "array", "items": s}}, ["tasks"]),
        t("tell", "Send a message to an agent by name.", {"name": s, "message": s}, ["name", "message"]),
        t("computer", "Start a computer-use task on a device.", {**dev, "task": s}, ["device", "task"]),
        t("shell", "Run a command on a device and return its output and exit code.",
          {**dev, "command": s}, ["device", "command"]),
        t("read", "Read a text file on a device.", {**dev, "path": s, "offset": i, "limit": i, "at": i},
          ["device", "path"]),
        t("write", "Write a whole file on a device.", {**dev, "path": s, "content": s},
          ["device", "path", "content"]),
        t("edit", "Replace text in files on a device.",
          {**dev, "edits": {"type": "array", "items": edit, "minItems": 1}}, ["device", "edits"]),
    ]


def unii_blocks(lines):
    """Memory.view: <chat>, 4-line blocks, one mark at the last whole block."""
    whole = len(lines) // 4
    blocks = [{"type": "text", "text": "<chat>\n"}]
    if whole == 0:
        blocks[0]["cache_control"] = {"type": "ephemeral"}
    for k in range(whole):
        b = {"type": "text", "text": "".join(lines[k * 4:(k + 1) * 4])}
        if k == whole - 1:
            b["cache_control"] = {"type": "ephemeral"}
        blocks.append(b)
    blocks.append({"type": "text", "text": "".join(lines[whole * 4:]) + "</chat>\n"})
    return blocks


def unii_turn(args, system, lines, msg):
    blocks = unii_blocks(lines) + [
        {"type": "text", "text": "Devices open now:\n(None is open now.)\n\n"},
        {"type": "text", "text": "Agents at work now: none.\n\n"},
        {"type": "text", "text": "Turn: the user's new message:\n\n" + msg + "\n" + ASK,
         "cache_control": {"type": "ephemeral"}},
    ]
    body = {
        "model": args.model, "max_tokens": 2000, "stream": True,
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "thinking": {"type": "adaptive", "display": "summarized"},
        "output_config": {"effort": args.effort},
        "cache_control": {"type": "ephemeral"},
        "tools": unii_tools(),
        "messages": [{"role": "user", "content": blocks}],
    }
    url = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/") + "/v1/messages"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers(args.sticky))
    t0 = time.monotonic()
    first = None
    text = []
    use = {}
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            ev = json.loads(line[5:])
            ty = ev.get("type")
            if ty == "message_start":
                use.update(ev["message"].get("usage") or {})
            elif ty == "content_block_delta":
                d = ev.get("delta", {})
                if d.get("type") in ("text_delta", "thinking_delta") and first is None:
                    first = time.monotonic() - t0
                if d.get("type") == "text_delta":
                    text.append(d["text"])
            elif ty == "message_delta":
                use.update({k: v for k, v in (ev.get("usage") or {}).items() if v is not None})
    total = time.monotonic() - t0
    return {"ttft_s": first, "start_s": 0.0, "turn_s": total, "usage": usage_of(use), "reply": "".join(text)}


# The Chief harness ---------------------------------------------------------

def chief_turn(args, system_file, view, delta, prev_end, msg, cwd):
    """One turn as a fresh Claude Code process with our marks (input_layout)."""
    mark = {"type": "ephemeral", "ttl": "1h"}
    content = [{"type": "text", "text": "<chat>\n" + "".join(view) + "</chat>\n", "cache_control": dict(mark)}]
    for k, d in enumerate(delta):
        b = {"type": "text", "text": d}
        if k == prev_end:
            b["cache_control"] = dict(mark)
        content.append(b)
    content.append({"type": "text", "text": msg + "\n" + ASK, "cache_control": dict(mark)})
    env = dict(os.environ)
    env.update({"DISABLE_PROMPT_CACHING": "1", "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
                "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"})
    env.pop("CLAUDECODE", None)
    hdr = [l for l in (env.get("ANTHROPIC_CUSTOM_HEADERS") or "").splitlines()
           if l.strip() and not l.lower().startswith("x-subrouter-session")]
    if args.sticky:
        hdr.append("X-Subrouter-Session: " + args.sticky)
    env["ANTHROPIC_CUSTOM_HEADERS"] = "\n".join(hdr)
    argv = [args.claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--model", args.model, "--effort", args.effort,
            "--system-prompt-file", system_file, "--setting-sources", "project",
            "--disable-slash-commands", "--tools", "Bash,Read,Edit,Write,WebFetch,WebSearch,ToolSearch",
            "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    t0 = time.monotonic()
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n")
    p.stdin.close()
    first = start = None
    text, use, reqs = [], None, []
    for line in p.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "system" and start is None:
            start = time.monotonic() - t0
        if ev.get("type") == "stream_event":
            e = ev.get("event", {})
            if e.get("type") == "message_start":
                reqs.append(usage_of(e["message"].get("usage") or {}))
            if e.get("type") == "content_block_delta" and first is None and \
                    e.get("delta", {}).get("type") in ("text_delta", "thinking_delta"):
                first = time.monotonic() - t0
            if e.get("type") == "content_block_delta" and e.get("delta", {}).get("type") == "text_delta":
                text.append(e["delta"]["text"])
        if ev.get("type") == "result":
            use = usage_of(ev.get("usage") or {})
    p.wait()
    total = time.monotonic() - t0
    return {"ttft_s": first, "start_s": start, "turn_s": total, "usage": use or {}, "requests": len(reqs),
            "first_request": reqs[0] if reqs else None, "reply": "".join(text)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--harness", choices=["unii", "chief"], required=True)
    ap.add_argument("--unii-src", default="")
    ap.add_argument("--chief-system", default="")
    ap.add_argument("--model", default="claude-opus-5-5")
    ap.add_argument("--effort", default="medium")
    ap.add_argument("--turns", type=int, default=6)
    ap.add_argument("--view-kb", type=int, default=100)
    ap.add_argument("--sticky", default="")
    ap.add_argument("--claude", default="claude")
    args = ap.parse_args()
    lines = view_lines(args.view_kb)
    rows = []
    if args.harness == "unii":
        system = open(os.path.join(args.unii_src, "prompt.txt"), encoding="utf-8").read()
    else:
        system_file = args.chief_system
        cwd = tempfile.mkdtemp(prefix="chief-bench-")
        delta, prev_end, base = [], None, len(lines) * 256
    for k, msg in enumerate(TURNS[:args.turns]):
        mid = (len(lines) + k * 2) * 256 + k
        if args.harness == "unii":
            r = unii_turn(args, system, lines, msg)
            lines = lines + [f"{base_id(lines)}|user: {msg}\n", f"{base_id(lines) + 1}|unii: {flat(r['reply'])}\n"]
        else:
            r = chief_turn(args, system_file, lines, delta, prev_end, f"{mid}|user: {msg}", cwd)
            prev_end = len(delta)
            delta = delta + [f"{mid}|user: {msg}\n", f"{mid + 1}|talk: {flat(r['reply'])}\n"]
        u = r["usage"]
        den = u.get("input", 0) + u.get("cache_read", 0) + u.get("cache_write", 0)
        row = {"harness": args.harness, "turn": k + 1, "model": args.model, "sticky": bool(args.sticky),
               "ttft_s": round(r["ttft_s"], 3) if r["ttft_s"] is not None else None,
               "start_s": round(r["start_s"], 3) if r.get("start_s") is not None else None,
               "turn_s": round(r["turn_s"], 3), **u,
               "hit": round(u.get("cache_read", 0) / den, 3) if den else None,
               "cost_usd": round(cost(args.model, u, args.harness == "chief"), 5)}
        if args.harness == "chief":
            row["requests"] = r["requests"]
            row["first_request"] = r["first_request"]
        rows.append(row)
        print("UNII-BENCH " + json.dumps(row), flush=True)
    warm = rows[1:]
    tot = {k: sum(r.get(k, 0) or 0 for r in warm) for k in ("input", "cache_read", "cache_write", "output")}
    den = tot["input"] + tot["cache_read"] + tot["cache_write"]
    summary = {"harness": args.harness, "sticky": bool(args.sticky), "warm_turns": len(warm),
               "warm_hit": round(tot["cache_read"] / den, 3) if den else None,
               "ttft_p50_s": p50([r["ttft_s"] for r in rows if r["ttft_s"] is not None]),
               "turn_p50_s": p50([r["turn_s"] for r in rows]),
               "cost_total_usd": round(sum(r["cost_usd"] for r in rows), 4),
               "prompt_tokens_turn1": rows[0]["input"] + rows[0]["cache_read"] + rows[0]["cache_write"] if rows else None}
    print("UNII-BENCH-SUMMARY " + json.dumps(summary), flush=True)


def base_id(lines):
    return 100000 + len(lines)


def flat(s):
    return " ".join((s or "").split())[:400]


def p50(a):
    a = sorted(a)
    return a[len(a) // 2] if a else None


if __name__ == "__main__":
    sys.exit(main())
