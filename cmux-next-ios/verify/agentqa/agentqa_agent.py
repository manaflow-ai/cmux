#!/usr/bin/env python3
"""Credit-free ACP agent for the agent chat stress pass (verify/agentqa/README.md).

It is acpmux's own test agent (`cmux-tui/crates/acpmux/tests/fake_agent.py`,
path in FAKE_AGENT) plus prompts that load the phone's chat the way long real
sessions do:

  "md: N"        streams a long markdown answer in N sections (heading, list,
                 table, code block, inline code, link), ~40 chars per chunk at
                 30 ms: a big transcript built from a real stream
  "flood: N"     N chunks of ~12 chars with no delay between them: the
                 per-chunk cost of streaming
  "tools: N"     N tool calls (read, search, execute), each pending then
                 completed with output, then a one-line answer
  "seq: N"       N numbered chunks "<k>|" 20 ms apart: order and loss checks
                 read the final text back
  "long: S"      streams one chunk a second for S seconds (honours cancel):
                 a turn that outlives backgrounding and reconnects
  "think: N"     N thought lines, 0.5 s apart, then a one-line answer
  "turns-done"   a short answer, for many-turn runs

Every other prompt is fake_agent's (ask:, question:, slow, until-cancel, echo, ...).
"""
import importlib.util
import os
import sys
import time

spec = importlib.util.spec_from_file_location("fake_agent", os.environ["FAKE_AGENT"])
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)
base_prompt = fake.handle_prompt

LANGS = ["swift", "rust", "python", "typescript"]
CODE = {
    "swift": "struct Item {\n    var id: Int\n    var name: String\n\n    func describe() -> String {\n        \"Item #\\(id): \\(name)\"\n    }\n}",
    "rust": "fn checksum(bytes: &[u8]) -> u32 {\n    bytes.iter().fold(0u32, |acc, b| acc.rotate_left(5) ^ u32::from(*b))\n}",
    "python": "def chunks(seq, n):\n    for i in range(0, len(seq), n):\n        yield seq[i:i + n]",
    "typescript": "export function debounce<T extends unknown[]>(fn: (...a: T) => void, ms: number) {\n  let t: ReturnType<typeof setTimeout> | undefined;\n  return (...a: T) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };\n}",
}


def chunk(sid, text):
    fake.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})


def end(rid, reason="end_turn"):
    fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": reason}})


def cancelled(sid, rid):
    if sid in fake.cancelled:
        fake.cancelled.discard(sid)
        end(rid, "cancelled")
        return True
    return False


def section(k):
    lang = LANGS[k % len(LANGS)]
    return (
        f"## Section {k}: {lang} notes\n\n"
        f"Step {k} reads `Sources/Module{k}/File{k}.{lang}` and checks the edge cases in "
        f"[the design doc](https://example.com/doc/{k}). It keeps the **public API** stable.\n\n"
        f"- first point for section {k}, short\n"
        f"- second point, with a longer sentence that wraps on a phone to check line height and spacing\n"
        f"- third point with `inline_code_{k}()`\n\n"
        f"| Case | Before | After |\n|---|---|---|\n| empty | {k} ms | {k // 2} ms |\n| large | {k * 10} ms | {k * 3} ms |\n\n"
        f"```{lang}\n{CODE[lang]}\n```\n\n"
    )


def stream_text(sid, rid, text, size=40, delay=0.03):
    for i in range(0, len(text), size):
        if cancelled(sid, rid):
            return False
        chunk(sid, text[i:i + size])
        if delay:
            time.sleep(delay)
    return True


def handle_prompt(rid, params):
    sid = params["sessionId"]
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    head = text.split(":")[0].strip().lower()
    # The phone's keyboard capitalizes the first letter.
    if head in ("md", "flood", "tools", "seq", "long", "think", "ask", "question", "slow"):
        text = head + text[len(head):]
        params = dict(params, prompt=[{"type": "text", "text": text}])
    arg = text.split(":", 1)[1].strip() if ":" in text else ""
    if head in ("md", "flood", "tools", "seq", "long", "think"):
        # A cancel that came while no turn ran must not end this one.
        fake.cancelled.discard(sid)
    if text.startswith("md:"):
        n = int(arg or "10")
        body = f"# Long answer, {n} sections\n\n" + "".join(section(k) for k in range(1, n + 1)) + "Done: all sections streamed.\n"
        if stream_text(sid, rid, body):
            end(rid)
        return
    if text.startswith("flood:"):
        n = int(arg or "500")
        for k in range(n):
            if cancelled(sid, rid):
                return
            chunk(sid, f"tok{k:05d} ")
        chunk(sid, "\nflood done")
        end(rid)
        return
    if text.startswith("seq:"):
        n = int(arg or "200")
        for k in range(1, n + 1):
            if cancelled(sid, rid):
                return
            chunk(sid, f"{k}|")
            time.sleep(0.02)
        chunk(sid, " seq-end")
        end(rid)
        return
    if text.startswith("tools:"):
        n = int(arg or "10")
        kinds = [("read", "Read Sources/File{}.swift"), ("search", "Search for TODO in module {}"),
                 ("execute", "Run swift test --filter Case{}")]
        for k in range(1, n + 1):
            if cancelled(sid, rid):
                return
            kind, title = kinds[k % len(kinds)]
            call = {"toolCallId": f"t{rid}-{k}", "title": title.format(k), "kind": kind,
                    "rawInput": {"command": f"step {k}"} if kind == "execute" else {"path": f"Sources/File{k}.swift"}}
            fake.update(sid, dict(call, sessionUpdate="tool_call", status="in_progress"))
            time.sleep(0.15)
            out = "\n".join(f"line {i} of output for step {k}" for i in range(1, 6))
            fake.update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call["toolCallId"], "status": "completed",
                              "content": [{"type": "content", "content": {"type": "text", "text": out}}]})
        chunk(sid, f"Ran {n} tools.")
        end(rid)
        return
    if text.startswith("long:"):
        secs = int(arg or "60")
        for k in range(secs):
            if cancelled(sid, rid):
                return
            chunk(sid, f"[{k + 1}s] ")
            time.sleep(1.0)
        chunk(sid, "long-done")
        end(rid)
        return
    if text.startswith("think:"):
        n = int(arg or "12")
        for k in range(1, n + 1):
            if cancelled(sid, rid):
                return
            fake.update(sid, {"sessionUpdate": "agent_thought_chunk",
                              "content": {"type": "text", "text": f"Thought line {k}: checking the next part of the plan.\n"}})
            time.sleep(0.5)
        chunk(sid, "Thought it through.")
        end(rid)
        return
    if text.strip() == "turns-done":
        chunk(sid, "ok")
        end(rid)
        return
    return base_prompt(rid, params)


fake.handle_prompt = handle_prompt


def tap(stream):
    """Follows the session folder (session/new and session/load carry cwd), as e2e_agent does."""
    import json
    for line in stream:
        try:
            msg = json.loads(line)
            if msg.get("method") in ("session/new", "session/load"):
                cwd = (msg.get("params") or {}).get("cwd")
                if cwd:
                    os.chdir(cwd)
        except (ValueError, OSError):
            pass
        yield line


sys.stdin = tap(sys.stdin)
fake.main()
