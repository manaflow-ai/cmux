#!/usr/bin/env python3
"""team_eval.py's numbers that need no model: python3 -m unittest test_team_eval (from measure/)."""
import json
import os
import subprocess
import sys
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

    def test_messages_seen_in_the_same_ms_keep_their_order(self):
        messages = [msg(1, "user_local", "hi"), msg(2, "agent_mux", "a"), msg(3, "agent_mux", "b")]
        t = team_eval.timeline({"brief": 1000}, messages, {"m1": 1000, "m2": 2000, "m3": 2000})
        self.assertEqual(t["brief"]["first_reply_ms"], 1000)

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
        for arm in ("B", "B2"):
            self.assertEqual(team_eval.ARMS[arm]["tools"], "spawn,tell")
            self.assertNotEqual(team_eval.ARMS[arm]["grace"], "0")


class SpendTests(unittest.TestCase):
    def test_a_transcript_counts_each_message_once_and_grows_live(self):
        import tempfile
        d = tempfile.mkdtemp()
        proj = os.path.join(d, ".claude", "projects", "-tmp-repo")
        os.makedirs(proj)
        f = os.path.join(proj, "s1.jsonl")
        line = lambda mid, out: json.dumps({"type": "assistant", "message": {"id": mid, "model": "claude-opus-5-5",
                                            "usage": {"input_tokens": 1000, "output_tokens": out}}}) + "\n"
        open(f, "w").write(line("m1", 100) + line("m1", 1000))  # a streamed copy: the last wins
        meter = team_eval.LiveMeter([d, None])
        self.assertAlmostEqual(meter.usd(), (1000 * 5 + 1000 * 25) / 1e6)
        with open(f, "a") as fh:
            fh.write(line("m2", 0) + '{"type": "assistant", "message": {"id": "m3"')  # m3 is half written
        self.assertAlmostEqual(meter.usd(), (2000 * 5 + 1000 * 25) / 1e6)

    def test_an_unknown_model_is_priced_as_the_dearest_and_cache_writes_by_ttl(self):
        u = {"cache_creation_input_tokens": 10**6, "cache_creation": {"ephemeral_5m_input_tokens": 10**6}}
        self.assertEqual(team_eval.usage_usd("claude-opus-5-5", u), 6.25)
        self.assertEqual(team_eval.usage_usd("claude-opus-5-5", {"cache_creation_input_tokens": 10**6}), 10.0)
        self.assertEqual(team_eval.usage_usd("some-new-model", {"output_tokens": 10**6}), 25.0)

    def test_the_ledger_never_lets_the_eval_pass_its_cap(self):
        import tempfile
        path = os.path.join(tempfile.mkdtemp(), "ledger.json")
        led = team_eval.Ledger(path, 60)
        self.assertEqual(led.reserve("r1", 25, 3), ("r1-a1", 25))   # committed 28
        other = team_eval.Ledger(path, 60)                          # a second campaign process
        self.assertEqual(other.reserve("r2", 25, 3), ("r2-a1", 25))  # 56: it sees r1
        self.assertIsNone(led.reserve("r3", 25, 3))                 # 60 - 56 - 3 = 1 < 5: it sees r2
        led.settle("r1-a1", 7.5)                                    # 7.5 + 28 = 35.5
        self.assertEqual(other.reserve("r3", 25, 3), ("r3-a1", 21))  # cut to fit: 60 - 35.5 - 3
        other.settle("r2-a1", None)                                 # unknown keeps its 28
        self.assertIsNone(led.reserve("r2", 25, 3))                 # a retry fits no more: 60 - 59.5 - 3
        led.settle("r3-a1", 4.0)                                    # 7.5 + 28 + 4 = 39.5
        self.assertEqual(led.reserve("r2", 25, 3), ("r2-a2", 17))   # a new attempt; a1 keeps its 28
        self.assertAlmostEqual(team_eval.Ledger(path, 60).committed(), 39.5 + 20)
        self.assertIsNone(led.reserve("r1", 25, 3))                 # a finished run never reruns
        with self.assertRaises(SystemExit):
            team_eval.Ledger(path, 800)                             # one cap per eval

    def test_step_spend_reads_the_higher_of_trace_and_live(self):
        out = 'x\nTEAM-EVAL {"cost_usd": {"all": 4.0, "live": 4.5}}\n'
        self.assertEqual(team_eval.step_spend(out), 4.5)
        self.assertIsNone(team_eval.step_spend("no line"))

    def test_followup_skew(self):
        task = {"followups": [{"id": "status", "at": 120}, {"id": "scope", "at": 360}]}
        self.assertEqual(team_eval.followup_skew({"brief": 1000, "status": 121500}, task), {"status": 0.5})


class PinTests(unittest.TestCase):
    ENV = dict(team_eval.PIN_ENV)

    def test_opus_medium_everywhere_passes_and_the_compactor_is_recorded_apart(self):
        ev = [{"ev": "request", "turn": "t1", "model": "claude-opus-5-5"},
              {"ev": "turn.end", "model": "claude-opus-5-5", "effort": "medium"},
              {"ev": "node", "model": "claude-haiku-5-5"}]
        p = team_eval.pin_check(self.ENV, {"claude-opus-5-5-20261001"}, ev)
        self.assertTrue(p["ok"], p)
        self.assertEqual(p["compactor_models"], ["claude-haiku-5-5"])

    def test_another_model_effort_or_env_fails(self):
        self.assertFalse(team_eval.pin_check(self.ENV, {"claude-sonnet-5-5"})["ok"])
        self.assertFalse(team_eval.pin_check(self.ENV, set(), [{"ev": "turn.end", "model": "claude-opus-5-5",
                                                               "effort": "high"}])["ok"])
        self.assertFalse(team_eval.pin_check(dict(self.ENV, OPTCHAT_SUBAGENT_EFFORT="low"), {"claude-opus-5-5"})["ok"])
        self.assertFalse(team_eval.pin_check(self.ENV, set())["ok"])  # nothing answered: unproven
        self.assertFalse(team_eval.is_pinned_model("claude-opus-5-55"))

    def test_a_spawn_at_another_effort_fails_and_compactor_requests_do_not(self):
        ok = [{"ev": "turn.end", "model": "claude-opus-5-5", "effort": "medium"},
              {"ev": "request", "node": "5236+4", "model": "claude-haiku-5-5"}]  # a compactor node's request
        self.assertTrue(team_eval.pin_check(self.ENV, set(), ok)["ok"])
        high = ok + [{"ev": "tool", "name": "mcp__optchat__spawn", "args": {"tasks": ["x"], "effort": "high"}}]
        self.assertEqual(team_eval.pin_check(self.ENV, set(), high)["bad"], ["effort high"])
        blind = ok + [{"ev": "tool", "name": "spawn", "args_bytes": 40}]
        self.assertFalse(team_eval.pin_check(self.ENV, set(), blind)["ok"])  # no args: unproven


FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, subprocess, sys
p = os.path.join(os.environ["HOME"], ".claude", "projects", "-x")
os.makedirs(p, exist_ok=True)
for n, line in enumerate(sys.stdin):
    if n == 0:
        open("touched.txt", "w").write("x\\n")
        subprocess.run(["sh", "-c", "git add -A && git commit -qm agent"], check=True)
        subprocess.run(["gh", "pr", "view", "1"])
    with open(os.path.join(p, "s.jsonl"), "a") as f:
        f.write(json.dumps({"type": "assistant", "message": {"id": f"m{n}", "model": os.environ["FAKE_MODEL"],
                                                            "usage": {"output_tokens": 1000}}}) + "\\n")
    print(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": f"reply {n}"}]}}), flush=True)
    print(json.dumps({"type": "result", "total_cost_usd": 0.025 * (n + 1)}), flush=True)
"""


class LossyRunTests(unittest.TestCase):
    """The whole arm L loop, with a fake claude on a one-file repo (a few seconds)."""

    def run_l(self, model):
        import tempfile
        d = tempfile.mkdtemp(prefix="te-test.", dir="/tmp")
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        src = os.path.join(d, "src")
        os.makedirs(os.path.join(d, "home", ".local", "bin"))
        os.makedirs(src)
        open(os.path.join(src, "a.txt"), "w").write("a\n")
        g = ["git", "-C", src, "-c", "user.name=x", "-c", "user.email=x@x"]
        subprocess.run(["git", "init", "-q", "-b", "main", src], check=True)
        subprocess.run(g + ["add", "-A"], check=True)
        subprocess.run(g + ["commit", "-qm", "base"], check=True)
        sha = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        claude = os.path.join(d, "home", ".local", "bin", "claude")
        open(claude, "w").write(FAKE_CLAUDE)
        os.chmod(claude, 0o755)
        task = json.load(open(os.path.join(HERE, "team_eval_tasks.json")))["tasks"][1]
        task = dict(task, base=sha, followups=[dict(f, at=i + 1) for i, f in enumerate(task["followups"])])
        json.dump({"tasks": [task]}, open(os.path.join(d, "tasks.json"), "w"))
        env = dict(os.environ, HOME=os.path.join(d, "home"))
        pins = [x for k, v in team_eval.PIN_ENV.items() for x in ("--env", f"{k}={v}")]
        r = subprocess.run([sys.executable, os.path.join(HERE, "team_eval.py"), "run", "--task", task["id"], "--arm", "L",
                            "--tasks", os.path.join(d, "tasks.json"), "--bins", d, "--repo", src,
                            "--out", os.path.join(d, "out"), "--keep-repo", os.path.join(d, "repo"),
                            "--quiet-seconds", "1", "--max-minutes", "1", *pins, "--env", f"FAKE_MODEL={model}"],
                           env=env, capture_output=True, text=True, timeout=120)
        return r, json.load(open(os.path.join(d, "out", "run.json")))

    def test_a_pinned_run_ends_idle_with_its_timeline_cost_diff_and_stub_calls(self):
        r, run = self.run_l("claude-opus-5-5")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(run["end"], "idle")
        self.assertTrue(run["pin"]["ok"])
        self.assertEqual(set(run["followup_skew_s"]), {"status", "scope", "side", "correction"})
        self.assertLess(max(run["followup_skew_s"].values()), 2)
        self.assertIsNotNone(run["timeline"]["brief"]["first_reply_ms"])
        self.assertAlmostEqual(run["cost_usd"]["live"], 5 * 1000 * 25 / 1e6)
        self.assertGreater(run["diff_lines"], 0)
        self.assertEqual(run["stub_calls"], 1)
        self.assertIn("no process holds its locks", r.stdout)

    def test_another_model_stops_the_run_and_fails_it(self):
        r, run = self.run_l("claude-sonnet-5-5")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(run["end"], "pin")
        self.assertFalse(run["pin"]["ok"])


class CampaignOutcomeTests(unittest.TestCase):
    def test_a_void_attempt_costs_nothing_and_its_run_may_run_again(self):
        import tempfile
        led = team_eval.Ledger(os.path.join(tempfile.mkdtemp(), "l.json"), 60)
        key, _ = led.reserve("r1", 25, 3)
        led.void(key, "step1", ["no run.json"])
        self.assertEqual(led.committed(), 0)
        self.assertEqual(led.reserve("r1", 25, 3), ("r1-a2", 25))

    def campaign_with(self, stderr, rc, **more):
        import argparse
        import shutil
        import tempfile
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        workers = more.pop("workers", {"m1": {"last_seen": now}, "m2": {"last_seen": now}})
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        os.makedirs(os.path.join(d, "bin"))
        fake = os.path.join(d, "bin", "cmux-ci")
        with open(fake, "w") as f:
            f.write(f"#!/bin/sh\necho \"$*\" >> {d}/calls\n"
                    f"[ \"$1\" = workers ] && {{ echo '{json.dumps(workers)}'; exit 0; }}\n"
                    f"echo {json.dumps(stderr)} >&2\nexit {rc}\n")
        os.chmod(fake, 0o755)
        opts = argparse.Namespace(ledger=os.path.join(d, "l.json"), cap_usd=100, out=os.path.join(d, "out"), reps=1,
                                  task=["t"], arm=["A"], name="x", run_budget=25, margin=12, ref="r", base_url="u",
                                  minutes=5, parallel=1, worker=[])
        vars(opts).update(more)
        self.calls = os.path.join(d, "calls")
        path = os.environ["PATH"]
        os.environ["PATH"] = os.path.join(d, "bin") + os.pathsep + path
        try:
            team_eval.campaign(opts)
        finally:
            os.environ["PATH"] = path
        return team_eval.Ledger(opts.ledger, 100)

    def test_a_step_the_controller_refused_is_void(self):
        led = self.campaign_with("cmux-ci: controller HTTP 400: invalid ci-step: script is not on the ci-step allowlist", 1)
        self.assertEqual(led.committed(), 0)

    def test_a_step_with_no_id_and_no_refusal_keeps_its_reservation(self):
        led = self.campaign_with("cmux-ci: connection reset", 1)
        self.assertEqual(led.committed(), 37)

    def test_a_refusal_after_the_step_existed_keeps_its_reservation(self):
        led = self.campaign_with("cmux-ci: step s1 (exclusive, key x-A)\ncmux-ci: controller HTTP 404: no such step", 1)
        self.assertEqual(led.committed(), 37)

    def test_each_step_runs_on_a_named_worker(self):
        self.campaign_with("cmux-ci: controller HTTP 400: no", 1, arm=["A", "B", "B2"], parallel=3, worker=["m1", "m2"])
        runs = [c.split() for c in open(self.calls).read().splitlines() if c.startswith("run ")]
        self.assertEqual(len(runs), 3)
        self.assertTrue(all(c[c.index("--target-worker") + 1] in ("m1", "m2") for c in runs))

    def test_an_unknown_worker_stops_the_campaign_before_any_reservation(self):
        with self.assertRaises(SystemExit):
            self.campaign_with("", 0, worker=["m1", "typo"])

    def test_a_listed_but_offline_worker_stops_the_campaign_before_any_reservation(self):
        with self.assertRaises(SystemExit) as e:
            self.campaign_with("", 0, worker=["m1"], workers={"m1": {"last_seen": "2026-09-25T00:00:00Z"}})
        self.assertIn("not live", str(e.exception))
        self.assertEqual(open(self.calls).read(), "workers\n")

    def test_a_worker_seen_with_a_short_fraction_is_live(self):
        from datetime import datetime, timezone
        seen = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + ".73317Z"
        self.campaign_with("cmux-ci: controller HTTP 400: no", 1, worker=["m1"], workers={"m1": {"last_seen": seen}})
        self.assertIn("--target-worker m1", open(self.calls).read())

    def test_no_worker_means_no_target(self):
        self.campaign_with("cmux-ci: controller HTTP 400: no", 1)
        self.assertNotIn("--target-worker", open(self.calls).read())

    def test_a_short_ref_is_refused_before_any_reservation(self):
        import argparse
        self.assertEqual(team_eval.full_sha("a" * 40), "a" * 40)
        for bad in ("ec65b11c722", "A" * 40, "feat-cmux-next"):
            with self.assertRaises(argparse.ArgumentTypeError):
                team_eval.full_sha(bad)

    def test_a_409_for_an_existing_key_keeps_its_reservation(self):
        led = self.campaign_with("cmux-ci: controller HTTP 409: step_key already names a different step", 1)
        self.assertEqual(led.committed(), 37)

    def test_the_scorer_excludes_failed_and_off_pin_runs(self):
        import team_eval_score
        self.assertIsNone(team_eval_score.excluded({"ok": True, "failed": [], "pin": {"ok": True}}))
        self.assertTrue(team_eval_score.excluded({"ok": False, "failed": ["driver exit 3 (pin)"], "pin": {"ok": False}}))
        self.assertTrue(team_eval_score.excluded({"pin": {"ok": True}}))  # never packed by the step


if __name__ == "__main__":
    unittest.main()
