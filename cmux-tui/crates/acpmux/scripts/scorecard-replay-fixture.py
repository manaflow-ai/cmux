#!/usr/bin/env python3
"""Scrub one recorded chat log into a scorecard-replay fixture (RFD 0161).

    python3 -I scripts/scorecard-replay-fixture.py SESSION_DIR OUT_HOME FIXTURE_ID [--turns-after N]

SESSION_DIR is a copy of `<state>/sessions/<id>` (its `events/*.ndjson`). The fixture keeps only the
record kinds `src/scorecard_replay.rs` reads, and of them only the fields it reads: numbers, the model,
tool names, record kinds and states. Every text (prompts, tool inputs and outputs, paths, commands,
host, session and chat names) is dropped or replaced: a tool input's path, command, URL or pattern
becomes a stable pseudonym (the same value, the same pseudonym, so a re-read stays a re-read), and a
tool output becomes as many `x` as it had characters (its size is what invariant 3 reads). Times are
shifted to a fixed epoch. With --turns-after N the log is cut N turns after its first compaction.
Writes OUT_HOME/sessions/FIXTURE_ID/{session.json,events/000001.ndjson}.
"""

import argparse
import glob
import json
import os
import sys

EPOCH = 1_700_000_000_000
KINDS = {
    "forked",
    "claude.system.init",
    "claude.stream_event",
    "usage_update",
    "compaction",
    "claude.system.compact_boundary",
    "harness_surgery",
    "config_option_update",
    "tool_call",
    "tool_call_update",
    "turn_started",
}
INPUT_KEYS = {
    "file_path": "/fixture/file-{}",
    "notebook_path": "/fixture/notebook-{}",
    "command": "command-{}",
    "url": "https://example.invalid/{}",
    "pattern": "pattern-{}",
    "path": "/fixture/dir-{}",
}
USAGE_KEYS = [
    "sessionUpdate",
    "inputTokens",
    "cachedReadTokens",
    "cachedWriteTokens",
    "outputTokens",
    "used",
    "size",
    "contextTokens",
]
SURGERY_KEYS = [
    "applied",
    "maskedResults",
    "charsMasked",
    "tokensBefore",
    "tokensAfter",
    "keepTurns",
    "minChars",
]


class Scrub:
    def __init__(self, fixture_id):
        self.id = fixture_id
        self.names = {}
        self.calls = {}
        self.shift = None
        self.turns = 0

    def pseudonym(self, key, value):
        table = self.names.setdefault(key, {})
        if value not in table:
            table[value] = INPUT_KEYS[key].format(len(table) + 1)
        return table[value]

    def at(self, t):
        if self.shift is None:
            self.shift = EPOCH - t
        return t + self.shift

    def update(self, kind, update):
        return {"jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": self.id, "update": update}}

    def record(self, r):
        kind, msg = r["kind"], r.get("msg")
        msg = msg if isinstance(msg, dict) else {}
        u = msg.get("params", {}).get("update", {}) if isinstance(msg.get("params"), dict) else {}
        out = None
        if kind == "forked":
            out = {}
        elif kind == "claude.system.init":
            out = {k: msg[k] for k in ("type", "subtype", "model", "tools", "output_style") if k in msg}
        elif kind == "claude.stream_event":
            ev = msg.get("event") or {}
            if ev.get("type") != "message_start":
                return None
            out = {"type": "stream_event", "parent_tool_use_id": msg.get("parent_tool_use_id"),
                   "event": {"type": "message_start",
                             "message": {"model": (ev.get("message") or {}).get("model")}}}
        elif kind == "usage_update":
            nu = {k: u[k] for k in USAGE_KEYS if k in u}
            meta = (u.get("_meta") or {}).get("acpmux") or {}
            m = {k: meta[k] for k in ("call", "cacheHit") if k in meta}
            if isinstance(meta.get("cacheExpiresAt"), int):
                m["cacheExpiresAt"] = self.at(meta["cacheExpiresAt"])
            if m:
                nu["_meta"] = {"acpmux": m}
            out = self.update(kind, nu)
        elif kind == "compaction":
            out = self.update(kind, {k: u[k] for k in ("sessionUpdate", "state") if k in u})
        elif kind == "claude.system.compact_boundary":
            cm = msg.get("compact_metadata") or {}
            out = {"type": "system", "subtype": "compact_boundary",
                   "compact_metadata": {k: cm[k] for k in ("trigger", "pre_tokens", "post_tokens")
                                        if k in cm}}
        elif kind == "harness_surgery":
            out = {k: msg[k] for k in SURGERY_KEYS if k in msg}
        elif kind == "config_option_update":
            out = self.update(kind, {"sessionUpdate": "config_option_update"})
        elif kind in ("tool_call", "tool_call_update"):
            tid = u.get("toolCallId")
            if tid not in self.calls:
                self.calls[tid] = "toolu_fixture_{}".format(len(self.calls) + 1)
            nu = {"sessionUpdate": kind, "toolCallId": self.calls[tid]}
            for k in ("kind", "status"):
                if k in u:
                    nu[k] = u[k]
            tool = ((u.get("_meta") or {}).get("claude") or {}).get("tool")
            if tool:
                nu["_meta"] = {"claude": {"tool": tool}}
            raw = u.get("rawInput")
            if isinstance(raw, dict):
                nu["rawInput"] = {k: self.pseudonym(k, v) for k, v in raw.items()
                                  if k in INPUT_KEYS and isinstance(v, str) and v}
            if isinstance(u.get("content"), list):
                n = sum(len((c.get("content") or {}).get("text") or "")
                        for c in u["content"]
                        if isinstance(c, dict) and isinstance(c.get("content"), dict))
                nu["content"] = [{"type": "content", "content": {"type": "text", "text": "x" * n}}]
            out = self.update(kind, nu)
        elif kind == "turn_started":
            self.turns += 1
            out = {"turnId": "turn-{}".format(self.turns)}
        return {"seq": r["seq"], "at": self.at(r["at"]), "dir": r.get("dir", "in"),
                "kind": kind, "msg": out}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session_dir")
    ap.add_argument("out_home")
    ap.add_argument("fixture_id")
    ap.add_argument("--turns-after", type=int)
    a = ap.parse_args()
    s = Scrub(a.fixture_id)
    lines, past_compact_boundary, turns_after, first_at = [], False, 0, None
    for path in sorted(glob.glob(os.path.join(a.session_dir, "events", "*.ndjson"))):
        with open(path) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("kind") not in KINDS:
                    continue
                if a.turns_after is not None and past_compact_boundary and r["kind"] == "turn_started":
                    turns_after += 1
                    if turns_after > a.turns_after:
                        break
                out = s.record(r)
                if out is None:
                    continue
                first_at = out["at"] if first_at is None else first_at
                lines.append(json.dumps(out, separators=(",", ":")))
                if r["kind"] == "claude.system.compact_boundary":
                    past_compact_boundary = True  # fleet-only-ok: local parse state of this scan, not a setting
    last_at = json.loads(lines[-1])["at"] if lines else EPOCH
    last_seq = json.loads(lines[-1])["seq"] if lines else 0
    d = os.path.join(a.out_home, "sessions", a.fixture_id)
    os.makedirs(os.path.join(d, "events"), exist_ok=True)
    meta = {"schema": "acpmux.session.v1", "id": a.fixture_id, "name": a.fixture_id,
            "harness": "claude", "family": "claude", "cwd": "/fixture", "status": "idle",
            "createdAt": first_at or EPOCH, "updatedAt": last_at, "lastSeq": last_seq}
    with open(os.path.join(d, "session.json"), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    with open(os.path.join(d, "events", "000001.ndjson"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("{}: {} records, {} tool calls, {} turns".format(a.fixture_id, len(lines), len(s.calls),
                                                          s.turns), file=sys.stderr)


if __name__ == "__main__":
    main()
