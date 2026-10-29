#!/usr/bin/env python3
"""Credit-free ACP agent for the live end-to-end pass (verify/e2e-live.md).

It is acpmux's own test agent (`cmux-tui/crates/acpmux/tests/fake_agent.py`,
path in FAKE_AGENT) plus two prompts it lacks:

  "edit: PATH"   appends a line to PATH (relative to the session folder), and
                 reports it as an ACP `edit` tool call with a `diff` block, so
                 the phone's diff viewer and artifacts browser see a real edit
  "stream: N"    streams N short chunks, 120 ms apart, then ends the turn
  "multi: Q"     asks Q as Claude Code's AskUserQuestion with multiSelect and
                 three options, and echoes the answers (verify/push-matrix.md)

Every other prompt (`ask:`, `question:`, `slow`, echo, ...) is fake_agent's.
"""
import importlib.util
import json
import os
import time

spec = importlib.util.spec_from_file_location("fake_agent", os.environ["FAKE_AGENT"])
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)

original_prompt = fake.handle_prompt


def chunk(sid, text):
    fake.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})


def handle_prompt(rid, params):
    sid = params["sessionId"]
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    # The phone's keyboard capitalizes the first letter.
    if text[:1].isupper() and text.split(":")[0].lower() in ("edit", "stream", "ask", "question", "slow", "multi"):
        text = text[0].lower() + text[1:]
        params = dict(params, prompt=[{"type": "text", "text": text}])
    if text.startswith("edit:"):
        path = text[5:].strip()
        full = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
        old = open(full).read() if os.path.exists(full) else ""
        new = old + f"edited from the phone at {time.strftime('%H:%M:%S')}\n"
        with open(full, "w") as f:
            f.write(new)
        call = {"toolCallId": f"edit-{rid}", "title": f"Edit {path}", "kind": "edit", "status": "completed",
                "locations": [{"path": full}], "rawInput": {"file_path": full},
                "content": [{"type": "diff", "path": full, "oldText": old, "newText": new}]}
        fake.update(sid, dict(call, sessionUpdate="tool_call"))
        chunk(sid, f"Edited `{path}`: one line added.")
        fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("multi:"):
        res = fake.request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "q1", "title": "Question", "kind": "other", "status": "pending",
                             "rawInput": {"questions": [{"question": text[6:].strip(), "header": "Checks",
                                                         "multiSelect": True,
                                                         "options": [{"label": "lint"}, {"label": "unit tests"},
                                                                     {"label": "e2e"}]}]},
                             "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": True}}},
                "options": [
                    {"optionId": "allow_once", "name": "Answer", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
                ],
            },
        )
        res = res or {}
        chosen = res.get("outcome", {}).get("optionId", res.get("outcome", {}).get("outcome"))
        answers = res.get("_meta", {}).get("updatedInput", {}).get("answers")
        chunk(sid, f"chose {chosen} {json.dumps(answers, sort_keys=True)}")
        fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("stream:"):
        count = int(text[7:].strip() or "20")
        for n in range(count):
            if sid in fake.cancelled:
                fake.cancelled.discard(sid)
                fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            chunk(sid, f"word{n} ")
            time.sleep(0.12)
        fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    return original_prompt(rid, params)


fake.handle_prompt = handle_prompt

# Remember the session folder (session/new and session/load carry cwd)
# without changing fake_agent's reader: tap its stdin.
import json
import sys


def tap(stream):
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
