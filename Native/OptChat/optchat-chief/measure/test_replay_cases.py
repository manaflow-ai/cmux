#!/usr/bin/env python3
"""replay_cases.py on a small made-up memory (no real messages).

Run from measure/: python3 -m unittest test_replay_cases
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "replay_cases.py")


def at(seconds):
    h, rest = divmod(36000 + seconds, 3600)
    m, s = divmod(rest, 60)
    return f"2026-10-26T{h:02d}:{m:02d}:{s:02d}.000-07:00"


def spawn(cwd, title):
    return "mcp__optchat__spawn " + json.dumps({"cwd": cwd, "tasks": [f"Title: {title}\nGroup: G\n..."]})


# id: (seconds, kind, text)
MESSAGES = {
    1: (0, "user", "please always put a Group line in every task you start"),
    2: (5, "tool", 'mcp__optchat__send {"reply_to":1,"text":"Will do: every task gets a Group."}'),
    3: (60, "user", "fix the sidebar flicker when a workspace closes"),       # accepted dispatch
    4: (70, "tool", spawn("~/fun/cmux", "Sidebar flicker")),
    5: (71, "echo", 'Started a1 in /x. - a1: workspace "Sidebar flicker" in group "G"'),
    6: (200, "user", "make the tab bar thinner in compact mode please"),     # corrected next
    7: (210, "tool", spawn("~/fun/cmux", "Tab bar")),
    8: (300, "user", "no i said the pinned tab bar"),
    9: (400, "user", "the composer loses focus [image sha256:abc]"),          # has an image
    10: (500, "user", "rename the settings button to Preferences"),          # no spawn at all
    11: (505, "talk", "Done, renamed."),
    12: (600, "user", "the cmuxterm-hq dashboard shows a stale build number"),  # accepted, other repo
    13: (610, "tool", spawn("/Users/me/fun/cmuxterm-hq", "Stale build")),
    14: (700, "user", "thanks"),
}
for k in range(15, 40):  # filler between the rule and its later dispatch
    MESSAGES[k] = (800 + k, "talk", f"status {k}")
MESSAGES[40] = (2000, "user", "add a shortcut to reopen the last closed workspace")
MESSAGES[41] = (2010, "tool", spawn("~/fun/cmux", "Reopen shortcut"))
MESSAGES[42] = (2100, "user", "great")
MESSAGES[43] = (2200, "user", "the alarm skips nothing after the button press")  # repo only in old memory
MESSAGES[44] = (2210, "tool", spawn("~/fun/sleep-alarm", "Alarm skip"))


class ReplayCases(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.db = os.path.join(cls.tmp.name, "memory.sqlite3")
        conn = sqlite3.connect(cls.db)
        conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, kind TEXT, date TEXT, text TEXT)")
        for i, (secs, kind, text) in sorted(MESSAGES.items()):
            conn.execute("INSERT INTO messages VALUES (?, ?, ?, ?)", (i, kind, at(secs), text))
        conn.commit()
        conn.close()
        cls.out = os.path.join(cls.tmp.name, "cases")
        cls.result = subprocess.run(
            [sys.executable, "-I", SCRIPT, "--db", cls.db, "--out", cls.out,
             "--dispatch", "3,6,9,10,43", "--feedback", "12", "--rule", "group:1"],
            capture_output=True, text=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def case(self, cid):
        with open(os.path.join(self.out, cid + ".json")) as f:
            return json.load(f)

    def test_only_accepted_spawns_become_cases(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        self.assertEqual(sorted(os.listdir(self.out)),
                         ["dispatch-m3.json", "feedback-m12.json", "rules-group-m1-m40.json"])
        self.assertIn("skipped 6: no accepted spawn", self.result.stdout)   # corrected
        self.assertIn("skipped 9: has an image", self.result.stdout)
        self.assertIn("skipped 10: no accepted spawn", self.result.stdout)
        self.assertIn("skipped 43: its repo is named only in older memory", self.result.stdout)

    def test_a_dispatch_checks_repo_key_words_and_title(self):
        checks = self.case("dispatch-m3")["turns"][0]["checks"]
        res = [c.get("re") for c in checks]
        self.assertIn("Title:", res)
        # Any one of the words of 5+ letters the accepted task ("Sidebar flicker") kept.
        self.assertIn("(?i)sidebar|flicker", res)
        words = next(r for r in res if r and r.startswith("(?i)sidebar"))
        self.assertNotIn("workspace", words, "the accepted task did not keep it")
        cwd = next(r for r in res if r and r.startswith('"cwd"'))
        import re
        self.assertRegex('{"cwd":"~/fun/cmux","tasks":[]}', cwd)
        self.assertRegex('{"cwd":"/home/person/fun/cmux","tasks":[]}', cwd)
        self.assertNotRegex('{"cwd":"~/fun/cmuxterm-hq","tasks":[]}', cwd)
        self.assertIn({"type": "no_question"}, checks)
        self.assertTrue(re.compile(cwd))

    def test_the_accepted_repo_is_the_one_expected(self):
        cwd = next(c["re"] for c in self.case("feedback-m12")["turns"][0]["checks"]
                   if c.get("re", "").startswith('"cwd"'))
        self.assertRegex('{"cwd":"~/fun/cmuxterm-hq"}', cwd)
        self.assertNotRegex('{"cwd":"~/fun/cmux"}', cwd)

    def test_a_rule_case_holds_the_rule_and_its_answer_and_a_neutral_profile(self):
        c = self.case("rules-group-m1-m40")
        self.assertEqual([h["kind"] for h in c["history"]], ["user", "talk"])
        self.assertIn("Group line", c["history"][0]["text"])
        self.assertEqual(c["history"][1]["text"], "Will do: every task gets a Group.")
        self.assertEqual(c["turns"][0]["text"], MESSAGES[40][2])
        self.assertIn({"type": "called", "cmd": "spawn", "re": "(?i)group:"}, c["turns"][0]["checks"])
        self.assertNotIn("Group", c["person"])

    def test_the_history_is_the_messages_before_in_the_runners_kinds(self):
        h = self.case("dispatch-m3")["history"]
        self.assertEqual(h, [
            {"kind": "user", "text": MESSAGES[1][2]},
            {"kind": "talk", "text": "Will do: every task gets a Group."},
        ])

    def test_the_history_shows_what_chief_already_started(self):
        h = self.case("feedback-m12")["history"]
        self.assertIn({"kind": "talk", "text": "Started a1: Sidebar flicker"}, h)

    def test_cases_inside_a_git_work_tree_are_refused(self):
        r = subprocess.run(
            [sys.executable, "-I", SCRIPT, "--db", self.db, "--out", os.path.join(HERE, "no-cases"),
             "--dispatch", "3"],
            capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 2)
        self.assertIn("inside a git work tree", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(HERE, "no-cases")))


if __name__ == "__main__":
    unittest.main()
