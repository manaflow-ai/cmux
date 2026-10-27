#!/usr/bin/env python3
"""chief_health.py on a small Chief home with known answers.

Run from measure/: python3 -m unittest test_chief_health
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "chief_health.py")

DAY = "2026-10-26"


def at(seconds):
    """A message date `seconds` after 10:00 on DAY, as the memory writes it."""
    h, rest = divmod(36000 + seconds, 3600)
    m, s = divmod(rest, 60)
    return f"{DAY}T{h:02d}:{m:02d}:{s:02d}.000-07:00"


# (seconds, kind, text): one conversation with every case the eval counts.
MESSAGES = [
    (0, "user", "fix the sidebar flicker"),                       # replied after 5 s
    (5, "tool", 'mcp__optchat__send {"reply_to":1,"text":"on it"}'),
    (6, "echo", "outcome: done. sent in the thread of message 1"),
    (100, "user", "first of a burst"),                            # burst: one reply at 190
    (110, "user", "second of a burst"),
    (190, "talk", "both done"),
    (300, "user", "ok"),                                          # an ack: not counted
    (400, "user", "change the tab bar"),                          # acted, never told
    (405, "tool", 'mcp__optchat__spawn {"tasks":["Title: Tab bar"]}'),
    (406, "echo", "Started a2. - a2: no cmux workspace (the session daemon was not reachable)"),
    (2000, "user", "is the build green"),                         # waits; then a ping
    (2100, "user", "hello?"),
    (2200, "user", "The server restarted, cutting the turn; nothing was lost: go on."),
    (2210, "note", "the turn failed (the turn stopped early (cancelled))"),
    (2300, "tool", 'Bash {"command":"cmux browser right navigate --url https://x.test --agent Chief"}'),
    (2301, "echo", "cmux: usage: cmux browser <tab_…|page|right> navigate URL | back"),
    (2302, "tool", 'Bash {"command":"cmux browser right navigate https://x.test --agent Chief"}'),
    (2303, "echo", "tab  tab_0123abcd"),
    (2304, "tool", 'mcp__optchat__spawn {"tasks":["Title: Build"]}'),
    (2305, "echo", 'Started a3. - a3: workspace "Build" in group "CI"'),
    (2310, "talk", "green"),
    (2400, "user", "[a3] report: done"),                          # a subagent report: not typed
]

NODES = [
    "user: fix the sidebar flicker; talk: on it",
    "I can't write this memory line. The input is a compaction request.",
    "Compacting 9. Writing the line now.\n\nI'm not writing this line.",
    "user: is the build green; talk: green",
]

TRACE = [
    {"ev": "turn.end", "status": "ok", "ms": 10000, "ttft_ms": 2000},
    {"ev": "turn.end", "status": "ok", "ms": 30000, "ttft_ms": 4000},
    {"ev": "turn.end", "status": "error", "ms": 500},
    {"ev": "turn.end", "status": "cancelled", "ms": 800},
    {"ev": "turn.end", "status": "stopped", "ms": 900},
    {"ev": "tool", "name": "bash", "ok": True},
    {"ev": "tool", "name": "spawn", "ok": False,
     "error": {"prefix": "<tool_use_error>Error: No such tool avai…"}},
    {"ev": "tool", "name": "zoom", "ok": False, "error": {"prefix": "exit 1"}},
]


def build_home(root):
    os.makedirs(os.path.join(root, "traces"))
    db = sqlite3.connect(os.path.join(root, "memory.sqlite3"))
    db.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, kind TEXT, date TEXT, day TEXT, text TEXT)")
    db.execute("CREATE TABLE nodes (level INTEGER, idx INTEGER, bytes INTEGER, day TEXT, text TEXT)")
    for i, (secs, kind, text) in enumerate(MESSAGES, start=1):
        db.execute("INSERT INTO messages VALUES (?, ?, ?, ?, ?)", (i, kind, at(secs), DAY, text))
    for i, text in enumerate(NODES):
        db.execute("INSERT INTO nodes VALUES (0, ?, ?, ?, ?)", (i, len(text), DAY, text))
    db.commit()
    db.close()
    ts = 1793034000000  # 2026-10-26 10:00 -07:00
    with open(os.path.join(root, "traces", f"{DAY}.jsonl"), "w") as f:
        for n, e in enumerate(TRACE):
            f.write(json.dumps({**e, "ts": ts + n}) + "\n")
        f.write("not json\n")


class ChiefHealth(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        build_home(cls.tmp.name)
        out = subprocess.run(
            [sys.executable, "-I", SCRIPT, "--home", cls.tmp.name, "--since", "1d",
             "--now", f"{DAY}T12:00:00-07:00", "--json"],
            capture_output=True, text=True, check=True,
        )
        cls.report = json.loads(out.stdout)
        cls.w = cls.report["window"]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_typed_messages_leave_out_acks_reports_and_notices(self):
        # sidebar, burst x2, tab bar, build, hello? (the ping is typed too)
        self.assertEqual(self.w["typed_messages"], 6)

    def test_a_burst_answered_together_counts_for_each_message(self):
        # 5 s (sidebar), 90 s and 80 s (burst), 310 s (build), 210 s (hello?)
        self.assertEqual(self.w["reply_s_p50"], 90.0)
        self.assertAlmostEqual(self.w["replied_within_10s_rate"], 1 / 6)

    def test_an_action_without_a_message_is_unanswered_and_counted_as_acted(self):
        self.assertEqual(self.w["unanswered"], 1)
        self.assertEqual(self.w["acted_without_reply"], 1)

    def test_a_ping_while_waiting_and_the_failures_the_person_saw(self):
        self.assertEqual(self.w["dead_chief_pings"], 1)
        self.assertEqual(self.w["restart_cut_turns"], 1)
        self.assertEqual(self.w["failed_turns_seen"], 1)

    def test_refusal_lines_include_a_refusal_after_a_lead_in(self):
        self.assertEqual(self.w["compactor_refusal_lines"], 2)
        self.assertEqual(self.w["memory_lines"], 4)

    def test_cmux_usage_errors_are_counted_by_command(self):
        self.assertEqual(self.w["cmux_calls"], 2)
        self.assertEqual(self.w["cmux_usage_errors"], 1)
        self.assertEqual(self.w["cmux_usage_error_shapes"], {"browser right navigate": 1})

    def test_spawns_without_a_workspace(self):
        self.assertEqual(self.w["subagents_started"], 2)
        self.assertEqual(self.w["subagents_without_workspace"], 1)

    def test_trace_turns_and_missing_tools(self):
        self.assertEqual(self.w["turns"], 5)
        self.assertEqual(self.w["turn_error_rate"], 0.2)
        self.assertEqual(self.w["turn_cancelled_rate"], 0.2)
        self.assertEqual(self.w["turn_stopped_by_chief_rate"], 0.2)
        self.assertEqual(self.w["turn_s_p50"], 30.0)
        self.assertEqual(self.w["no_such_tool"], 1)
        self.assertEqual(self.w["no_such_tool_names"], {"spawn": 1})

    def test_the_window_leaves_out_older_messages(self):
        out = subprocess.run(
            [sys.executable, "-I", SCRIPT, "--home", self.tmp.name, "--since", "1h",
             "--now", f"{DAY}T12:00:00-07:00", "--json"],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(json.loads(out.stdout)["window"]["typed_messages"], 0)

    def test_the_table_prints_without_json(self):
        out = subprocess.run(
            [sys.executable, "-I", SCRIPT, "--home", self.tmp.name, "--now", f"{DAY}T12:00:00-07:00"],
            capture_output=True, text=True, check=True,
        )
        self.assertIn("time to first reply, p50 (s)", out.stdout)
        self.assertIn("browser right navigate 1", out.stdout)


if __name__ == "__main__":
    unittest.main()
