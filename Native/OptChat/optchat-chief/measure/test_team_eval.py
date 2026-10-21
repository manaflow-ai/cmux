#!/usr/bin/env python3
"""team_eval.py's numbers that need no model: python3 -m unittest test_team_eval (from measure/)."""
import json
import os
import subprocess
import unittest

import team_eval

HERE = os.path.dirname(os.path.abspath(__file__))


def msg(i, author, text, key="k"):
    return {"id": f"m{i}", "seq": i, "author": author, "client_msg_id": key,
            "parts": [{"type": "text", "text": text}]}


class TimelineTests(unittest.TestCase):
    def test_a_receipt_is_the_first_reply_but_not_the_first_chief_reply(self):
        sent = {"brief": 1000, "status": 5000}
        messages = [
            msg(1, "user_local", "fix it"),
            msg(2, "agent_mux", "On it.", "turn:optchat:1:1"),
            msg(3, "user_local", "how's it going?"),
            msg(4, "agent_mux", "Got it. The Chief is busy", "voice:desk:turn:optchat:1:1:3"),
            msg(5, "agent_mux", "Halfway: the test is red.", "turn:optchat:3:2"),
        ]
        arrivals = {"m1": 1000, "m2": 4000, "m3": 5000, "m4": 10000, "m5": 65000}
        t = team_eval.timeline(sent, messages, arrivals)
        self.assertEqual(t["brief"]["first_reply_ms"], 3000)
        self.assertFalse(t["brief"]["first_reply_is_receipt"])
        self.assertEqual(t["status"]["first_reply_ms"], 5000)
        self.assertTrue(t["status"]["first_reply_is_receipt"])
        self.assertEqual(t["status"]["first_chief_reply_ms"], 60000)

    def test_no_reply_is_none(self):
        t = team_eval.timeline({"brief": 1000}, [msg(1, "user_local", "hi")], {"m1": 1000})
        self.assertIsNone(t["brief"]["first_reply_ms"])
        self.assertIsNone(t["brief"]["first_chief_reply_ms"])


class CostAndLeakTests(unittest.TestCase):
    def test_cost_counts_each_sessions_rise(self):
        # Running totals: the Chief's one session 0.5 -> 0.8, then a restart at 0.25;
        # subagent a1 0.5 -> 1.25, a2 0.25; a compactor node is its own process.
        ev = [{"ev": "turn.end", "cost_usd": 0.5}, {"ev": "subagent.answer", "id": "a1", "cost_usd": 0.5},
              {"ev": "turn.end", "cost_usd": 0.75}, {"ev": "subagent.answer", "id": "a2", "cost_usd": 0.25},
              {"ev": "subagent.answer", "id": "a1", "cost_usd": 1.25}, {"ev": "node", "cost_usd": 0.01},
              {"ev": "turn.start"}, {"ev": "turn.end", "cost_usd": None}, {"ev": "turn.end", "cost_usd": 0.25}]
        self.assertEqual(team_eval.trace_cost(ev), {"turns": 1.0, "subagents": 1.5, "compactor": 0.01, "all": 2.51})

    def test_a_mention_of_the_reference_is_a_leak(self):
        task = {"reference_pr": 22727, "reference": "26b1262ade8e52580112d39180286cc89e0ab7d6"}
        hits = team_eval.leak_hits([("message", "see #22727"), ("diff", "+ nothing"), ("stub", "26b1262ad"),
                                    ("tool", '{"ms": 1760022727123, "sha": "026b1262ad"}'),
                                    ("tool", "git show 26b1262ade8e52580112d39180286cc89e0ab7d6")], task)
        self.assertEqual([h["where"] for h in hits], ["message", "stub", "tool"])

    def test_the_stub_logs_valid_json(self):
        import tempfile
        d = tempfile.mkdtemp()
        log = os.path.join(d, "stubs.jsonl")
        team_eval.write_stubs(d, log)
        r = subprocess.run([os.path.join(d, "gh"), "pr", "create", "--title", 'a "quoted" \\ title'], capture_output=True)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(json.loads(open(log).read())["args"], ["pr", "create", "--title", 'a "quoted" \\ title'])


class TaskFileTests(unittest.TestCase):
    def test_every_task_is_complete_and_its_commits_exist(self):
        tasks = json.load(open(os.path.join(HERE, "team_eval_tasks.json")))["tasks"]
        self.assertTrue(tasks)
        for t in tasks:
            for field in ("id", "base", "reference", "reference_pr", "brief", "followups"):
                self.assertIn(field, t, t.get("id"))
            self.assertIn("{repo}", t["brief"], t["id"])
            ats = [f["at"] for f in t["followups"]]
            self.assertEqual(ats, sorted(ats), t["id"])
            for f in t["followups"]:
                self.assertTrue(f["adds"], (t["id"], f["id"]))
            for sha in (t["base"], t["reference"]):
                ok = subprocess.run(["git", "-C", HERE, "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True)
                if ok.returncode != 0:
                    self.skipTest(f"{sha} is not in this checkout (a shallow clone)")
            parent = subprocess.run(["git", "-C", HERE, "rev-parse", f"{t['reference']}^"], capture_output=True, text=True)
            self.assertEqual(parent.stdout.strip(), t["base"], f"{t['id']}: base is the reference's parent")


class LossyTests(unittest.TestCase):
    def test_assistant_text_blocks_are_the_agents_messages(self):
        events = [
            (1000, {"type": "eval.sent", "key": "te-brief-1", "text": "fix it"}),
            (2000, {"type": "assistant", "message": {"content": [{"type": "text", "text": "On it."},
                                                                 {"type": "tool_use", "name": "Bash"}]}}),
            (3000, {"type": "result", "total_cost_usd": 0.4}),
            (4000, {"type": "eval.sent", "key": "te-status-2", "text": "how's it going?"}),
            (9000, {"type": "assistant", "message": {"content": [{"type": "text", "text": "Done."}]}}),
            (9100, {"type": "result", "total_cost_usd": 0.9}),
        ]
        msgs, arrivals = team_eval.lossy_messages(events)
        self.assertEqual([(m["author"], team_eval.text_of(m)) for m in msgs],
                         [("user_local", "fix it"), ("agent_mux", "On it."), ("user_local", "how's it going?"), ("agent_mux", "Done.")])
        t = team_eval.timeline({"brief": 1000, "status": 4000}, msgs, arrivals)
        self.assertEqual((t["brief"]["first_reply_ms"], t["status"]["first_reply_ms"]), (1000, 5000))
        self.assertEqual(team_eval.lossy_cost(events), 0.9)


class ArmTests(unittest.TestCase):
    def test_heads_down_has_no_team_tools_and_no_receipts(self):
        self.assertEqual(team_eval.ARMS["A"]["tools"], "")
        self.assertEqual(team_eval.ARMS["A"]["grace"], "0")
        for arm in ("M", "D"):
            self.assertEqual(team_eval.ARMS[arm]["tools"], "spawn,tell")
            self.assertNotEqual(team_eval.ARMS[arm]["grace"], "0")


if __name__ == "__main__":
    unittest.main()
