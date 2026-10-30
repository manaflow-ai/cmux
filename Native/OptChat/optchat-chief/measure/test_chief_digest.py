#!/usr/bin/env python3
"""chief_digest.py on a small made-up Chief home.

Run from measure/: python3 -m unittest test_chief_digest
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "chief_digest.py")
DAY = "2026-10-26"


def at(seconds):
    h, rest = divmod(36000 + seconds, 3600)
    m, s = divmod(rest, 60)
    return f"{DAY}T{h:02d}:{m:02d}:{s:02d}.000-07:00"


MESSAGES = [
    (0, "user", "fix the sidebar flicker"),
    (5, "tool", 'mcp__optchat__spawn {"tasks":["Title: Tab bar"]}'),
    (6, "echo", "Started a1. - a1: no cmux workspace (opening it failed: PTY capacity exhausted)"),
    (60, "user", "no i said the sidebar, not the tab bar"),             # corrects message 1
    (70, "talk", "Sorry, on the sidebar now."),
    (200, "user", "is the build green"),                                # never answered
    (2000, "user", "The server restarted, cutting the turn; nothing was lost: go on."),
    (2010, "note", "the turn failed (API Error: 529 overloaded)"),
    (2100, "tool", 'Bash {"command":"cmux browser right navigate --url https://x.test"}'),
    (2101, "echo", "cmux: usage: cmux browser <tab_…|page|right> navigate URL"),
    (2200, "user", "ship it"),
    (2210, "talk", "Shipped."),
]
HOST_LOG = (f"{DAY} 10:36:41.000 optchat-chief: turn turn:optchat:11:x: a new message cannot reach it "
            "(steer unread past the deadline); interrupting\n")


class ChiefDigest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        db = os.path.join(cls.tmp.name, "memory.sqlite3")
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, kind TEXT, date TEXT, text TEXT)")
        for i, (secs, kind, text) in enumerate(MESSAGES, start=1):
            conn.execute("INSERT INTO messages VALUES (?, ?, ?, ?)", (i, kind, at(secs), text))
        conn.commit()
        conn.close()
        log = os.path.join(cls.tmp.name, "host.log")
        with open(log, "w") as f:
            f.write(HOST_LOG)
        cls.out = os.path.join(cls.tmp.name, "digest.html")
        cls.result = subprocess.run(
            [sys.executable, "-I", SCRIPT, "--db", db, "--host-log", log, "--since", "1d",
             "--now", f"{DAY}T12:00:00-07:00", "--out", cls.out],
            capture_output=True, text=True)
        with open(cls.out) as f:
            cls.page = f.read()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_each_kind_is_found_once(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        counts = dict(kv.split("=") for kv in self.result.stdout.split("\n")[1].split("; "))
        self.assertEqual(counts, {
            "corrected": "1", "no reply": "1", "message not delivered": "1", "turn failed": "1",
            "cut by restart": "1", "tool error": "1", "no workspace": "1",
        })

    def test_a_corrected_case_shows_the_ask_what_chief_did_and_the_correction(self):
        start = self.page.index('id="corrected"')
        end = self.page.find("<h2", start + 1)
        case = self.page[start:end if end > 0 else len(self.page)]
        self.assertIn("fix the sidebar flicker", case)
        self.assertIn("Title: Tab bar", case)
        self.assertIn("person (correction)", case)
        self.assertIn("no i said the sidebar", case)

    def test_plumbing_and_behavior_are_tagged(self):
        self.assertIn('class="case plumbing"', self.page)
        self.assertIn('class="case behavior"', self.page)

    def test_a_page_inside_a_git_work_tree_is_refused(self):
        r = subprocess.run(
            [sys.executable, "-I", SCRIPT, "--db", os.path.join(self.tmp.name, "memory.sqlite3"),
             "--out", os.path.join(HERE, "no-digest.html")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.exists(os.path.join(HERE, "no-digest.html")))


if __name__ == "__main__":
    unittest.main()
