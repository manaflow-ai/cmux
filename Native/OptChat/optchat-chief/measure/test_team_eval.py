#!/usr/bin/env python3
"""team_eval.py's numbers that need no model: python3 -m unittest test_team_eval (from measure/)."""
import json
import os
import subprocess
import sys
import unittest

import team_eval

HERE = os.path.dirname(os.path.abspath(__file__))


def read(path):
    with open(path) as f:
        return f.read()


def load(path):
    return json.loads(read(path))


def write(path, text, mode="w"):
    with open(path, mode) as f:
        f.write(text)


def append(path, text):
    write(path, text, "a")


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
        self.assertEqual(json.loads(read(log))["args"], ["pr", "create", "--title", 'a "quoted" \\ title'])


class TaskFileTests(unittest.TestCase):
    def test_every_task_is_complete_and_its_commits_exist(self):
        tasks = load(os.path.join(HERE, "team_eval_tasks.json"))["tasks"]
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
        write(f, line("m1", 100) + line("m1", 1000))  # a streamed copy: the last wins
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


# One response's ANTHROPIC_LOG=debug lines from a real `claude -p` (2.1.305, through the sr2
# gateway, 2026-10-21), trimmed to the response's parts: the log prints its headers twice.
DEBUG_SAMPLE = """[log_d90acf, anthropic-workspace-id: "wrkspc_01CaViq8ZY5W7TomnzyPenGh", request-id: "req_010UkMXn2kP8WvvTaLbryLXo"] post http://sr2-gateway.tail137216.ts.net:4016/v1/messages?beta=true succeeded with status 200 in 2414ms
[log_d90acf] response start {
  status: 200,
  headers: {
    "anthropic-ratelimit-unified-5h-reset": "1792591200",
    "anthropic-ratelimit-unified-5h-status": "allowed",
    "anthropic-ratelimit-unified-5h-utilization": "0.6",
    "anthropic-ratelimit-unified-7d-reset": "1792962000",
    "anthropic-ratelimit-unified-7d-status": "allowed",
    "anthropic-ratelimit-unified-7d-utilization": "0.53",
    "anthropic-ratelimit-unified-fallback": "available",
    "anthropic-ratelimit-unified-overage-status": "rejected",
    "anthropic-ratelimit-unified-representative-claim": "five_hour",
    "anthropic-ratelimit-unified-reset": "1792591200",
    "anthropic-ratelimit-unified-status": "allowed",
    "request-id": "req_010UkMXn2kP8WvvTaLbryLXo",
  },
  durationMs: 2414,
}
response 200 http://sr2-gateway.tail137216.ts.net:4016/v1/messages?beta=true Headers {
  "anthropic-ratelimit-unified-5h-reset": "1792591200",
  "anthropic-ratelimit-unified-5h-status": "allowed",
  "anthropic-ratelimit-unified-5h-utilization": "0.6",
  "anthropic-ratelimit-unified-7d-reset": "1792962000",
  "anthropic-ratelimit-unified-7d-status": "allowed",
  "anthropic-ratelimit-unified-7d-utilization": "0.53",
  "anthropic-ratelimit-unified-fallback": "available",
  "anthropic-ratelimit-unified-overage-status": "rejected",
  "anthropic-ratelimit-unified-representative-claim": "five_hour",
  "anthropic-ratelimit-unified-reset": "1792591200",
  "anthropic-ratelimit-unified-status": "allowed",
  "request-id": "req_010UkMXn2kP8WvvTaLbryLXo",
} ReadableStream { locked: false, state: 'readable', supportsBYOB: false }"""

FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, subprocess, sys
p = os.path.join(os.environ["HOME"], ".claude", "projects", "-x")
os.makedirs(p, exist_ok=True)
sample = open(os.environ["FAKE_DEBUG"]).read() if os.environ.get("ANTHROPIC_LOG") == "debug" else ""
for n, line in enumerate(sys.stdin):
    print(json.dumps({"type": "user", "isReplay": True, "uuid": json.loads(line).get("uuid")}), flush=True)
    print(sample, flush=True)
    if n == 0:
        open("touched.txt", "w").write("x\\n")
        subprocess.run(["sh", "-c", "git add -A && git commit -qm agent"], check=True)
        subprocess.run(["gh", "pr", "view", "1"])
    with open(os.path.join(p, "s.jsonl"), "a") as f:
        f.write(json.dumps({"type": "assistant", "message": {"id": f"m{n}", "model": os.environ["FAKE_MODEL"],
                                                            "usage": {"output_tokens": 1000, "cache_read_input_tokens": 10}}}) + "\\n")
    print(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": f"reply {n}"}]}}), flush=True)
    print(json.dumps({"type": "result", "total_cost_usd": 0.025 * (n + 1)}), flush=True)
"""


class LossyRunTests(unittest.TestCase):
    """The whole arm L loop, with a fake claude on a one-file repo (a few seconds)."""

    def run_l(self, model):
        import tempfile
        d = tempfile.mkdtemp(prefix="te-test.", dir="/tmp")
        self.addCleanup(subprocess.run, ["rm", "-rf", d])
        self.dir = d
        src = os.path.join(d, "src")
        os.makedirs(os.path.join(d, "home", ".local", "bin"))
        os.makedirs(src)
        write(os.path.join(src, "a.txt"), "a\n")
        g = ["git", "-C", src, "-c", "user.name=x", "-c", "user.email=x@x"]
        subprocess.run(["git", "init", "-q", "-b", "main", src], check=True)
        subprocess.run(g + ["add", "-A"], check=True)
        subprocess.run(g + ["commit", "-qm", "base"], check=True)
        sha = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        claude = os.path.join(d, "home", ".local", "bin", "claude")
        write(claude, FAKE_CLAUDE)
        os.chmod(claude, 0o755)
        task = load(os.path.join(HERE, "team_eval_tasks.json"))["tasks"][1]
        task = dict(task, base=sha, followups=[dict(f, at=i + 1) for i, f in enumerate(task["followups"])])
        write(os.path.join(d, "tasks.json"), json.dumps({"tasks": [task]}))
        write(os.path.join(d, "debug.txt"), DEBUG_SAMPLE)
        env = dict(os.environ, HOME=os.path.join(d, "home"))
        pins = [x for k, v in team_eval.PIN_ENV.items() for x in ("--env", f"{k}={v}")]
        r = subprocess.run([sys.executable, os.path.join(HERE, "team_eval.py"), "run", "--task", task["id"], "--arm", "L",
                            "--tasks", os.path.join(d, "tasks.json"), "--bins", d, "--repo", src,
                            "--out", os.path.join(d, "out"), "--keep-repo", os.path.join(d, "repo"),
                            "--quiet-seconds", "1", "--max-minutes", "1", *pins, "--env", f"FAKE_MODEL={model}",
                            "--env", f"FAKE_DEBUG={os.path.join(d, 'debug.txt')}"],
                           env=env, capture_output=True, text=True, timeout=120)
        return r, load(os.path.join(d, "out", "run.json"))

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
        # Every message was read (its echo) at once and answered; none waited.
        st = run["stall"]["summary"]
        self.assertEqual(st["messages"], 5)
        self.assertEqual(st["queued_over_10s"], {"count": 0, "of": 5, "rate": 0.0})
        self.assertEqual(st["never_started"], 0)
        self.assertEqual(st["busy"]["messages"], 0)
        self.assertTrue(all(m["lanes"] == 0 for m in run["stall"]["messages"].values()))
        self.assertEqual(run["tokens"], {"input": 0, "output": 5000, "cache_write": 0, "cache_read": 50, "total": 5050})
        # The headers claude printed: one reading per response (the fake repeats one).
        self.assertEqual(run["ratelimit"]["count"], 1)
        self.assertEqual(run["ratelimit"]["min_headroom"], 0.47)
        live = [l for l in r.stdout.splitlines() if l.startswith("TEAM-EVAL-RATELIMIT {")]
        self.assertEqual(len(live), 1)  # printed as claude's stdout was read, once per request id
        self.assertEqual(json.loads(live[0][len("TEAM-EVAL-RATELIMIT "):])["headroom"], 0.47)

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
        self.d = d
        self.addCleanup(shutil.rmtree, d, True)
        os.makedirs(os.path.join(d, "bin"))
        fake = os.path.join(d, "bin", "cmux-ci")
        with open(fake, "w") as f:
            f.write(f"#!/bin/sh\necho \"$*\" >> {d}/calls\n"
                    f"[ \"$1\" = workers ] && {{ echo '{json.dumps(workers)}'; exit 0; }}\n"
                    + more.pop("run", "").replace("{d}", d) +
                    f"echo {json.dumps(stderr)} >&2\nexit {rc}\n")
        os.chmod(fake, 0o755)
        opts = argparse.Namespace(ledger=os.path.join(d, "l.json"), cap_usd=100, out=os.path.join(d, "out"), reps=1,
                                  task=["t"], arm=["A"], name="x", run_budget=25, margin=12, ref="r", base_url="u",
                                  minutes=5, parallel=1, worker=[], label=[], max_concurrent=4, headroom_cmd="",
                                  min_headroom=0.25, headroom_window=20, headroom_max_age=30, headroom_sleep=180)
        vars(opts).update(more)
        self.calls = os.path.join(d, "calls")
        path = os.environ["PATH"]
        os.environ["PATH"] = os.path.join(d, "bin") + os.pathsep + path
        try:
            team_eval.campaign(opts)
        finally:
            os.environ["PATH"] = path
        return team_eval.Ledger(opts.ledger, opts.cap_usd)

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
        runs = [c.split() for c in read(self.calls).splitlines() if c.startswith("run ")]
        self.assertEqual(len(runs), 3)
        self.assertTrue(all(c[c.index("--target-worker") + 1] in ("m1", "m2") for c in runs))

    def test_an_unknown_worker_stops_the_campaign_before_any_reservation(self):
        with self.assertRaises(SystemExit):
            self.campaign_with("", 0, worker=["m1", "typo"])

    def test_a_listed_but_offline_worker_stops_the_campaign_before_any_reservation(self):
        with self.assertRaises(SystemExit) as e:
            self.campaign_with("", 0, worker=["m1"], workers={"m1": {"last_seen": "2026-09-25T00:00:00Z"}})
        self.assertIn("not live", str(e.exception))
        self.assertEqual(read(self.calls), "workers\n")

    def test_a_worker_seen_with_a_short_fraction_is_live(self):
        from datetime import datetime, timezone
        seen = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + ".73317Z"
        self.campaign_with("cmux-ci: controller HTTP 400: no", 1, worker=["m1"], workers={"m1": {"last_seen": seen}})
        self.assertIn("--target-worker m1", read(self.calls))

    def test_each_step_carries_the_extra_labels(self):
        self.campaign_with("cmux-ci: controller HTTP 400: no", 1, worker=["m1"], label=["measure", "bench"])
        self.assertIn("--label=measure --label=bench --target-worker m1", read(self.calls))

    def test_no_worker_means_no_target(self):
        self.campaign_with("cmux-ci: controller HTTP 400: no", 1)
        self.assertNotIn("--target-worker", read(self.calls))

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


class StallTests(unittest.TestCase):
    def test_waits_first_replies_and_busy_messages_are_summed_per_run(self):
        sent = {"brief": 0, "status": 60000, "scope": 120000, "side": 180000}
        starts = {"brief": 1000, "status": 75000, "scope": 121000, "side": None}  # side never started
        replies = {"brief": (4000, False), "status": (90000, False), "scope": (8000, False), "side": (None, True)}
        states = {"brief": (False, 0), "status": (True, 6), "scope": (True, 2), "side": (True, None)}
        st = team_eval.stall(sent, starts, replies, states, end_ms=200000)
        self.assertEqual(st["messages"]["status"]["wait_ms"], 15000)
        self.assertEqual(st["messages"]["side"]["waited_to_end_ms"], 20000)
        s = st["summary"]
        self.assertEqual((s["first_reply_p50_s"], s["first_reply_max_s"], s["no_reply"], s["reply_unattributable"]),
                         (8.0, 90.0, 0, 1))
        # status waited 15 s; side never started and waited 20 s to the end.
        self.assertEqual(s["queued_over_10s"], {"count": 2, "of": 4, "rate": 0.5})
        self.assertEqual(s["never_started"], 1)
        # Only status was mid-turn with 5+ subagents; side's lanes are unknown, so it is neither.
        self.assertEqual(s["busy"]["messages"], 1)
        self.assertEqual(s["busy"]["first_reply_p50_s"], 90.0)
        self.assertEqual(s["busy"]["unknown"], 1)

    def test_a_reply_is_credited_only_after_its_prompt_started_and_the_earlier_ones_reply(self):
        msgs = [msg(1, "user_local", "fix it"), msg(2, "agent_mux", "On it."), msg(3, "user_local", "status?"),
                msg(4, "agent_mux", "Done with the fix."), msg(5, "user_local", "and x?"),
                msg(6, "agent_mux", "Halfway."), msg(7, "user_local", "y?")]
        arrivals = {"m2": 2000, "m4": 30000, "m6": 50000}
        sent = {"brief": 1000, "status": 10000, "scope": 20000, "side": 60000}
        # status was read only at 40 s, so the 30 s message (the brief's turn) is not its reply;
        # scope started at 21 s, but its reply must come after status's (50 s): none is left.
        starts = {"brief": 1500, "status": 40000, "scope": 21000, "side": None}
        got = team_eval.attributed_replies(sent, starts, msgs, arrivals)
        self.assertEqual(got, {"brief": (1000, False), "status": (40000, False), "scope": (None, False),
                               "side": (None, True)})

    def test_two_replies_seen_in_one_poll_go_to_two_prompts(self):
        msgs = [msg(1, "user_local", "fix it"), msg(2, "user_local", "status?"),
                msg(3, "agent_mux", "Fixed."), msg(4, "agent_mux", "Status: done.")]
        arrivals = {"m3": 9000, "m4": 9000}  # one poll saw both
        got = team_eval.attributed_replies({"brief": 1000, "f1": 2000}, {"brief": 1100, "f1": 2100}, msgs, arrivals)
        self.assertEqual(got, {"brief": (8000, False), "f1": (7000, False)})

    def test_a_message_with_no_seq_does_not_break_the_order(self):
        msgs = [msg(1, "user_local", "fix it"), dict(msg(2, "agent_mux", "On it."), seq=None),
                msg(3, "agent_mux", "Done.")]
        got = team_eval.attributed_replies({"brief": 1000, "f1": 1500}, {"brief": 1100, "f1": 1600}, msgs,
                                           {"m2": 2000, "m3": 2000})
        self.assertEqual(got, {"brief": (1000, False), "f1": (500, False)})

    def test_a_resumed_subagent_runs_again(self):
        ev = [{"ts": 1, "ev": "subagent.start", "id": "a"}, {"ts": 2, "ev": "subagent.done", "id": "a"},
              {"ts": 3, "ev": "subagent.resume", "id": "a"}]
        self.assertEqual(team_eval.chief_state(ev, 2)[1], 0)
        self.assertEqual(team_eval.chief_state(ev, 3)[1], 1)

    def test_the_chief_state_comes_from_the_trace_at_the_send(self):
        ev = [{"ts": 10, "ev": "turn.start"}] + [{"ts": 20 + i, "ev": "subagent.start", "id": f"a{i}"} for i in range(6)]
        ev += [{"ts": 40, "ev": "subagent.done", "id": "a0"}, {"ts": 50, "ev": "turn.end"}]
        self.assertEqual(team_eval.chief_state(ev, 5), (False, 0))
        self.assertEqual(team_eval.chief_state(ev, 30), (True, 6))
        self.assertEqual(team_eval.chief_state(ev, 45), (True, 5))
        self.assertEqual(team_eval.chief_state(ev, 60), (False, 5))

    def test_the_chief_starts_a_message_when_its_read_cursor_reaches_it(self):
        messages = [{"seq": 1, "client_msg_id": "te-brief-1"}, {"seq": 3, "client_msg_id": "te-status-2"},
                    {"seq": 5, "client_msg_id": "te-scope-3"}]
        log = [(100, None), (900, 1), (5000, 2), (7000, 3)]
        got = team_eval.cursor_starts({"brief": "te-brief-1", "status": "te-status-2", "scope": "te-scope-3"},
                                      messages, log)
        self.assertEqual(got, {"brief": 900, "status": 7000, "scope": None})

    def test_arm_l_starts_a_message_at_its_echo_and_is_mid_turn_until_a_result(self):
        events = [(1000, {"type": "eval.sent"}), (1200, {"type": "user", "isReplay": True, "uuid": "u1"}),
                  (3000, {"type": "result"}), (4000, {"type": "eval.sent"}),
                  (4100, {"type": "assistant"}), (9000, {"type": "user", "isReplay": True, "uuid": "u2"})]
        self.assertEqual(team_eval.replay_starts({"brief": "u1", "status": "u2", "x": "u3"}, events),
                         {"brief": 1200, "status": 9000, "x": None})
        self.assertEqual(team_eval.lossy_state(events, 500), (False, 0))
        self.assertEqual(team_eval.lossy_state(events, 2000), (True, 0))
        self.assertEqual(team_eval.lossy_state(events, 3500), (False, 0))
        self.assertEqual(team_eval.lossy_state(events, 5000), (True, 0))

    def test_the_scorer_reports_stalls_and_tokens_per_run_and_per_arm(self):
        import argparse
        import shutil
        import tempfile
        import team_eval_score
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        judge = os.path.join(d, "judge")
        write(judge, "#!/bin/sh\necho '{}'\n")
        os.chmod(judge, 0o755)
        task = load(os.path.join(HERE, "team_eval_tasks.json"))["tasks"][0]
        msgs = {"brief": {"sent_ms": 0, "started_ms": 500, "wait_ms": 500, "first_reply_ms": 2000, "busy": False},
                "status": {"sent_ms": 1, "started_ms": 30001, "wait_ms": 30000, "first_reply_ms": 40000, "busy": True}}
        tok = {"input": 1, "output": 2, "cache_write": 3, "cache_read": 4, "total": 10}
        outs = []
        for i in range(2):
            out = os.path.join(d, f"r{i}")
            os.makedirs(out)
            write(os.path.join(out, "run.json"), json.dumps({"task": task["id"], "arm": "A-steer", "ok": True, "failed": [], "pin": {"ok": True},
                       "sent": {"brief": 0}, "timeline": {"brief": {"first_reply_ms": 2000}},
                       "cost_usd": {"all": 1.5}, "tokens": tok,
                       "stall": {"messages": msgs, "summary": team_eval.stall_summary(msgs.values())}}))
            write(os.path.join(out, "conversation.json"), json.dumps({"messages": [], "arrivals": {}}))
            write(os.path.join(out, "diff.patch"), "")
            outs.append(out)
        opts = argparse.Namespace(judge=judge, model="m")
        rows = [team_eval_score.score(o, [task], opts) for o in outs]
        self.assertEqual(rows[0]["stall"]["queued_over_10s"], {"count": 1, "of": 2, "rate": 0.5})
        self.assertEqual((rows[0]["tokens"], rows[0]["cost_usd"]), (tok, 1.5))
        arm = team_eval_score.by_arm(rows + [{"arm": "A-steer", "excluded": ["pin"]}])[0]
        self.assertEqual((arm["arm"], arm["runs"], arm["excluded"]), ("A-steer", 2, 1))
        self.assertEqual(arm["stall"]["messages"], 4)
        self.assertEqual(arm["stall"]["busy"]["first_reply_max_s"], 40.0)
        self.assertEqual(arm["tokens"]["total"], 20)
        self.assertEqual(arm["cost_usd"], 3.0)


class SteerArmTests(unittest.TestCase):
    def test_a_steer_is_arm_a_with_the_owners_stop(self):
        a, s = team_eval.ARMS["A"], team_eval.ARMS["A-steer"]
        self.assertEqual({k: v for k, v in s.items() if k != "interrupt"}, a)
        self.assertTrue(s["interrupt"])
        self.assertFalse(a.get("interrupt"))
        self.assertIn("A-steer", team_eval.CAMPAIGN_ARMS)

    def test_the_step_script_takes_the_arm(self):
        script = os.path.join(HERE, "..", "..", "..", "..", "scripts", "measure", "team-eval.sh")
        args = ["base_url=http://h:1", "task=t", "budget=0"]
        ok = subprocess.run(["bash", script, *args, "arm=A-steer"], capture_output=True, text=True)
        self.assertIn("budget is whole dollars", ok.stderr)  # past the arm check
        bad = subprocess.run(["bash", script, *args, "arm=Z"], capture_output=True, text=True)
        self.assertIn("arm=A|A-steer|B|B2|L", bad.stderr)


class TokenTests(unittest.TestCase):
    def test_tokens_come_from_transcripts_and_compactor_nodes(self):
        import tempfile
        d = tempfile.mkdtemp()
        proj = os.path.join(d, "projects", "-r")
        os.makedirs(proj)
        u = {"input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 30, "cache_read_input_tokens": 40}
        line = lambda mid: json.dumps({"type": "assistant", "message": {"id": mid, "model": "claude-opus-5-5", "usage": u}})
        write(os.path.join(proj, "s.jsonl"), line("m1") + "\n" + line("m1") + "\n" + line("m2") + "\n")
        self.assertEqual(team_eval.LiveMeter([d]).tokens(),
                         {"input": 20, "output": 40, "cache_write": 60, "cache_read": 80, "total": 200})
        ev = [{"ev": "node", "usage": {"input": 1, "cache_write": 2, "cache_read": 3, "output": 4}}, {"ev": "turn.end"}]
        self.assertEqual(team_eval.node_tokens(ev)["total"], 10)

    def test_a_ledger_with_no_cap_reserves_the_run_budget_and_sums_tokens(self):
        import tempfile
        path = os.path.join(tempfile.mkdtemp(), "l.json")
        led = team_eval.Ledger(path, None)
        self.assertIsNone(led.cap())
        self.assertEqual(led.reserve("r1", 25, 12), ("r1-a1", 25))
        self.assertEqual(led.reserve("r2", 25, 12), ("r2-a1", 25))
        self.assertEqual(led.reserve("r3", 25, 12), ("r3-a1", 25))  # 111 committed: no cap stops it
        led.settle("r1-a1", 2.0, tokens={"input": 1, "output": 2, "cache_write": 3, "cache_read": 4, "total": 10})
        led.settle("r2-a1", None)                                   # tokens unknown
        self.assertEqual(team_eval.Ledger(path, None).tokens()["total"], 10)
        with self.assertRaises(SystemExit):
            team_eval.Ledger(path, 800)                             # one cap per eval: none here


TEAM_EVAL_LINE = {"cost_usd": {"all": 3.0, "live": 3.5}, "failed": [], "ok": True, "started": True,
                  "pin": {"ok": True}, "tokens": {"input": 5, "output": 6, "cache_write": 7, "cache_read": 8, "total": 26},
                  "ratelimit": {"count": 3, "min_headroom": 0.4,
                                "last": {"at": 0, "7d_utilization": 0.5, "7d_status": "allowed", "headroom": 0.5}}}


class CampaignTests(unittest.TestCase):
    """The campaign's scheduler with a fake cmux-ci whose `run` prints a TEAM-EVAL line."""

    campaign_with = CampaignOutcomeTests.campaign_with

    def fake_run(self, body=""):
        return ("[ \"$1\" = run ] && { " + body + " echo 'cmux-ci: step s1 (exclusive)' >&2; "
                f"echo 'TEAM-EVAL {json.dumps(TEAM_EVAL_LINE)}'; exit 0; }}\n")

    def test_a_steps_tokens_and_reading_go_in_the_ledger_and_the_output(self):
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            led = self.campaign_with("", 1, run=self.fake_run(), cap_usd=None)
        self.assertEqual(led.tokens()["total"], 26)
        self.assertAlmostEqual(led.committed(), 3.5)
        self.assertEqual([r["source"] for r in led.readings()], ["team-eval-x-t-A-1-a1"])
        self.assertIn("ok, 26 tokens, spent $3.50; used 26 tokens, committed $3.50", buf.getvalue())
        self.assertNotIn(" of $", buf.getvalue())

    def test_no_more_than_max_concurrent_steps_run_at_once(self):
        stamp = "/usr/bin/python3 -c 'import time; print(time.time())'"
        body = (f"echo start $({stamp}) >> {{d}}/spans; sleep 0.4; echo end $({stamp}) >> {{d}}/spans;")
        self.campaign_with("", 1, run=self.fake_run(body), task=["t1", "t2", "t3"], arm=["A", "B"],
                           parallel=6, max_concurrent=2)
        spans = [l.split() for l in read(os.path.join(self.d, "spans")).splitlines()]
        self.assertEqual(sum(1 for k, _ in spans if k == "start"), 6)
        now, most = 0, 0
        for kind, _ in sorted(spans, key=lambda x: (float(x[1]), x[0] == "start")):
            now += 1 if kind == "start" else -1
            most = max(most, now)
        self.assertEqual(most, 2)

    def test_low_headroom_pauses_new_steps_until_it_comes_back(self):
        import contextlib
        import io
        # The command prints 0.1, then 0.9: the first check pauses, the next resumes.
        probe = os.path.join(self.tmp(), "probe")
        write(probe, "#!/bin/sh\nf=\"$0.n\"\nn=$(cat \"$f\" 2>/dev/null || echo 0)\n"
                               "echo $((n + 1)) > \"$f\"\n[ \"$n\" = 0 ] && echo 0.1 || echo 0.9\n")
        os.chmod(probe, 0o755)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            led = self.campaign_with("", 1, run=self.fake_run(), headroom_cmd=probe, headroom_sleep=0.01,
                                     headroom_max_age=0)
        out = buf.getvalue()
        self.assertIn("headroom 0.10 (lowest of 1 reading(s) in 0 min, probed) is under 0.25: pausing new steps", out)
        self.assertIn("headroom 0.90", out)
        self.assertIn("resuming", out)
        self.assertEqual(led.tokens()["total"], 26)  # the step ran after the resume

    def tmp(self):
        import shutil
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        return d


class HeadroomTests(unittest.TestCase):
    def test_the_parser_reads_one_reading_per_response_from_a_real_sample(self):
        rs = team_eval.ratelimit_readings(DEBUG_SAMPLE.splitlines(), at=7)
        self.assertEqual(rs, [{"at": 7, "request_id": "req_010UkMXn2kP8WvvTaLbryLXo", "status": "allowed",
                               "7d_utilization": 0.53, "7d_status": "allowed", "5h_utilization": 0.6, "5h_status": "allowed"}])
        self.assertAlmostEqual(team_eval.reading_headroom(rs[0]), 0.47)
        # The values the coordinator saw (7d 0.68, allowed), as acpmux logs a harness's stdout.
        other = DEBUG_SAMPLE.replace('"0.53"', '"0.68"').replace("req_010UkMXn2kP8WvvTaLbryLXo", "req_2")
        rs = team_eval.ratelimit_readings([(5, "[non-json stdout] " + l) for l in other.splitlines()])
        self.assertEqual((rs[0]["at"], rs[0]["request_id"], rs[0]["7d_utilization"]), (5, "req_2", 0.68))
        self.assertAlmostEqual(team_eval.reading_headroom(rs[0]), 0.32)
        self.assertEqual(team_eval.ratelimit_readings(["no headers", "}"]), [])

    def test_a_7d_status_other_than_allowed_is_no_headroom(self):
        self.assertEqual(team_eval.reading_headroom({"7d_utilization": 0.2, "7d_status": "rejected"}), 0.0)
        self.assertEqual(team_eval.reading_headroom({"7d_utilization": None, "7d_status": "allowed_warning"}), 0.0)
        self.assertIsNone(team_eval.reading_headroom({"7d_utilization": None, "7d_status": None}))

    def test_acpmux_session_logs_hold_the_chief_arms_readings(self):
        import tempfile
        home = tempfile.mkdtemp()
        ev = os.path.join(home, "sessions", "s1", "events")
        os.makedirs(ev)
        with open(os.path.join(ev, "000001.ndjson"), "w") as f:
            f.write(json.dumps({"seq": 1, "at": 99, "dir": "in", "kind": "claude.assistant", "msg": {}}) + "\n")
            for l in DEBUG_SAMPLE.splitlines():
                f.write(json.dumps({"at": 100, "dir": "mux", "kind": "stderr", "msg": {"text": "[non-json stdout] " + l}}) + "\n")
        rs = team_eval.acpmux_ratelimit(home)
        self.assertEqual([(r["at"], r["7d_utilization"]) for r in rs], [(100, 0.53)])
        self.assertEqual(team_eval.ratelimit_summary(rs)["last"]["headroom"], 0.47)
        self.assertEqual(team_eval.ratelimit_summary([])["count"], 0)

    def gate(self, readings, cmd="false", now=10000.0, window=20, max_age=1800):
        import tempfile
        led = team_eval.Ledger(os.path.join(tempfile.mkdtemp(), "l.json"), None)
        led.add_readings(readings)
        self.logs, self.slept = [], []
        return team_eval.Headroom(led, cmd, 0.25, window, max_age, 60, self.logs.append,
                                  sleep=self.slept.append, clock=lambda: now)

    def test_the_gate_reads_the_lowest_recent_reading_of_its_window(self):
        r = lambda at, util, status="allowed": {"at": at * 1000, "7d_utilization": util, "7d_status": status}
        g = self.gate([r(9000, 0.9), r(9500, 0.6), r(9900, 0.3)])
        self.assertEqual(round(g.current()[0], 2), 0.1)         # the fullest account sets it
        g = self.gate([r(7000, 0.95), r(9500, 0.6), r(9900, 0.3)])
        self.assertEqual(round(g.current()[0], 2), 0.4)         # the 0.95 is over 30 min old
        g = self.gate([r(9500, 0.99), r(9600, 0.2), r(9700, 0.1)], window=2)
        self.assertEqual(round(g.current()[0], 2), 0.8)         # the window holds the last 2
        g = self.gate([r(9500, 0.1, "rejected"), r(9600, 0.1)])
        self.assertEqual(g.current()[0], 0.0)                   # a refused account has no room

    def test_no_recent_reading_and_a_failing_or_garbage_probe_fail_closed(self):
        for cmd, why in (("false", "exit 1"), ("echo lots", "printed 'lots'"), ("echo 1.5", "printed '1.5'")):
            g = self.gate([{"at": 0, "7d_utilization": 0.1, "7d_status": "allowed"}], cmd=cmd)
            h, reason = g.current()
            self.assertIsNone(h, cmd)
            self.assertIn(why, reason)
        g = self.gate([], cmd="false")
        state = {"n": 0}

        def sleep(s):
            # The second check finds a fresh reading (a step's, say).
            state["n"] += 1
            g.ledger.add_readings([{"at": 10000 * 1000, "7d_utilization": 0.5, "7d_status": "allowed"}])
        g.sleep = sleep
        self.assertEqual(g.wait(), 0.5)
        self.assertEqual(state["n"], 1)
        self.assertIn("headroom unknown (no reading in 30 min and --headroom-cmd exit 1", self.logs[0])
        self.assertIn("failing closed", self.logs[0])
        self.assertIn("resuming", self.logs[1])

    def test_old_readings_added_late_never_push_a_fresh_low_one_out(self):
        fresh = {"at": 10000 * 1000, "request_id": "req_low", "7d_utilization": 0.9, "7d_status": "allowed"}
        g = self.gate([fresh], cmd="echo 0.8")
        # A step's summary re-adds 20 readings 40 minutes old after the fresh one.
        g.ledger.add_readings([{"at": (10000 - 2400) * 1000 + i, "request_id": f"old{i}", "7d_utilization": 0.2,
                                "7d_status": "allowed"} for i in range(20)])
        self.assertEqual([round(x, 2) for x in [g.current()[0]]], [0.1])
        self.assertFalse(g.ok())
        self.assertEqual(g.ledger.readings()[-1]["request_id"], "req_low")  # kept in time order

    def test_min_headroom_is_a_fraction(self):
        import argparse
        self.assertEqual(team_eval.fraction("0"), 0.0)
        for bad in ("-0.1", "1.5", "x"):
            with self.assertRaises(argparse.ArgumentTypeError):
                team_eval.fraction(bad)

    def test_a_live_reading_too_old_for_the_window_is_logged_not_raised(self):
        stale = {"at": 1000, "request_id": "req_old", "7d_utilization": 0.95, "7d_status": "allowed"}
        g = self.gate([stale], cmd="echo 0.9")              # the only reading is 2.7 h old
        g.note("k", stale)
        self.assertIn("headroom 0.05, but it is not among the recent readings", self.logs[-1])
        g = self.gate([stale], cmd="echo 0.9", window=1)
        g.ledger.add_readings([{"at": 10000 * 1000, "request_id": "req_x", "7d_utilization": 0.1}])
        g.note("k", stale)                                  # out of the window: the newer one is the minimum
        self.assertEqual(self.logs, [])

    def test_a_probe_reading_joins_the_window_and_no_command_only_warns(self):
        g = self.gate([], cmd="echo 0.6")
        self.assertEqual(g.wait(), 0.6)
        self.assertEqual([r["source"] for r in g.ledger.readings()], ["probe"])
        self.assertEqual(g.current()[1], "lowest of 1 reading(s) in 30 min")  # fresh: no second probe
        g = self.gate([], cmd="")
        self.assertIsNone(g.wait())
        self.assertEqual(len(self.logs), 1)
        self.assertIn("WARNING", self.logs[0])

    def test_the_probe_prints_the_headroom_of_a_real_claude_response_or_fails(self):
        import tempfile
        d = tempfile.mkdtemp()
        fake = os.path.join(d, "claude")
        write(os.path.join(d, "sample"), DEBUG_SAMPLE)
        write(fake, f"#!/bin/sh\n[ \"$ANTHROPIC_LOG\" = debug ] && cat {d}/sample\necho ok\n")
        os.chmod(fake, 0o755)
        probe = [sys.executable, os.path.join(HERE, "headroom_probe.py"), "--claude", fake]
        r = subprocess.run(probe, capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout), (0, "0.4700\n"), r.stderr)
        self.assertIn("one upstream account", r.stderr)
        write(fake, "#!/bin/sh\necho ok\n")
        r = subprocess.run(probe, capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout), (1, ""))
        # --base-url: claude -p goes through that route, with a placeholder key, no host token or
        # provider switch, and a scratch HOME and config dir (no host settings.json).
        write(fake, f"#!/bin/sh\necho \"$ANTHROPIC_BASE_URL $ANTHROPIC_API_KEY ${{ANTHROPIC_AUTH_TOKEN:-none}} "
                              f"${{CLAUDE_CODE_USE_BEDROCK:-none}} ${{AWS_PROFILE:-none}} $ANTHROPIC_LOG $HOME "
                              f"$CLAUDE_CONFIG_DIR\" > {d}/env\ncat {d}/sample\n")
        r = subprocess.run(probe + ["--base-url", "http://route:9"], capture_output=True, text=True,
                           env=dict(os.environ, ANTHROPIC_AUTH_TOKEN="host-token", CLAUDE_CODE_USE_BEDROCK="1",
                                    AWS_PROFILE="p"))
        self.assertEqual(r.returncode, 0, r.stderr)
        got = read(os.path.join(d, "env")).split()
        self.assertEqual(got[:6], ["http://route:9", "sk-ant-placeholder-the-route-signs", "none", "none", "none", "debug"])
        self.assertNotEqual(got[6], os.environ["HOME"])
        self.assertEqual(got[7], os.path.join(got[6], ".claude"))
        self.assertFalse(os.path.exists(got[6]))  # the scratch HOME is gone after


class LiveReadingTests(unittest.TestCase):
    def test_a_reading_is_one_flushed_line_on_stdout_and_the_live_fd_once_per_request(self):
        import contextlib
        import io
        r, w = os.pipe()
        self.addCleanup(os.close, r)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            live = team_eval.LiveReadings(w)
            rs = team_eval.ratelimit_readings(DEBUG_SAMPLE.splitlines(), at=3)
            live.emit(rs + rs + [{"at": 4, "7d_utilization": None, "7d_status": None}])
        os.close(w)
        sent = os.read(r, 1 << 16).decode()
        self.assertEqual(sent, buf.getvalue())
        self.assertEqual(sent.count("\n"), 1)
        self.assertTrue(sent.startswith("TEAM-EVAL-RATELIMIT {"))
        self.assertEqual(json.loads(sent.split(" ", 1)[1])["7d_utilization"], 0.53)

    def test_the_follower_reads_appended_bytes_and_new_session_logs_as_they_come(self):
        import queue
        import shutil
        import tempfile
        if not hasattr(team_eval.select, "kqueue"):
            self.skipTest("no kqueue")
        home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, home, True)
        got = queue.Queue()
        f = team_eval.AcpmuxFollower(home, lambda rs: [got.put(r) for r in rs], log=lambda m: None).start()
        self.addCleanup(f.stop)

        def records(text, req):
            out = ""
            for l in text.replace("req_010UkMXn2kP8WvvTaLbryLXo", req).splitlines():
                out += json.dumps({"at": 100, "dir": "mux", "kind": "stderr", "msg": {"text": "[non-json stdout] " + l}}) + "\n"
            return out

        one = records(DEBUG_SAMPLE, "req_a")
        ev1 = os.path.join(home, "sessions", "s1", "events")
        os.makedirs(ev1)  # a new session directory, then its log
        with open(os.path.join(ev1, "000001.ndjson"), "w") as fh:
            fh.write(one[:len(one) // 2])  # half a record: nothing yet
            fh.flush()
            fh.write(one[len(one) // 2:])
        self.assertEqual(got.get(timeout=10)["request_id"], "req_a")
        with open(os.path.join(ev1, "000001.ndjson"), "a") as fh:  # appended to the same log
            fh.write(records(DEBUG_SAMPLE.replace('"0.53"', '"0.9"'), "req_b"))
        r = got.get(timeout=10)
        self.assertEqual((r["request_id"], r["7d_utilization"]), ("req_b", 0.9))
        ev2 = os.path.join(home, "sessions", "s2", "events")
        os.makedirs(ev2)  # a second session (a subagent)
        write(os.path.join(ev2, "000001.ndjson"), records(DEBUG_SAMPLE, "req_c"))
        self.assertEqual(got.get(timeout=10)["request_id"], "req_c")
        f.stop()
        self.assertTrue(got.empty())  # each once

    def test_a_failing_callback_or_a_vanished_file_costs_one_pass_not_the_follower(self):
        import queue
        import shutil
        import tempfile
        if not hasattr(team_eval.select, "kqueue"):
            self.skipTest("no kqueue")
        home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, home, True)
        got, logs = queue.Queue(), []

        def on(rs):
            got.put(rs)
            if len(got.queue) == 1:
                raise RuntimeError("callback broke")
        f = team_eval.AcpmuxFollower(home, on, log=logs.append).start()
        self.addCleanup(f.stop)
        ev = os.path.join(home, "sessions", "s1", "events")
        os.makedirs(ev)
        line = lambda req: "".join(json.dumps({"at": 1, "kind": "stderr", "msg": {"text": l}}) + "\n"
                                   for l in DEBUG_SAMPLE.replace("req_010UkMXn2kP8WvvTaLbryLXo", req).splitlines())
        write(os.path.join(ev, "000001.ndjson"), line("req_a"))
        got.get(timeout=10)
        write(os.path.join(ev, "000002.ndjson"), line("req_b"))  # the thread lives on
        self.assertEqual(got.get(timeout=10)[0]["request_id"], "req_b")
        self.assertTrue(any("callback broke" in m for m in logs))
        f.stop()
        self.assertFalse(f.thread.is_alive())
        self.assertEqual(f.wake_r, -1)

    def test_wait_for_change_returns_on_a_write_and_at_the_deadline(self):
        import tempfile
        import threading
        import time
        path = os.path.join(tempfile.mkdtemp(), "trace.jsonl")
        write(path, "")
        t = time.time()
        team_eval.wait_for_change([path], 0.3)
        self.assertGreaterEqual(time.time() - t, 0.25)
        threading.Timer(0.2, lambda: append(path, "x\n")).start()
        t = time.time()
        team_eval.wait_for_change([path], 10)
        self.assertLess(time.time() - t, 5)

    def test_a_change_before_the_watch_is_never_waited_for(self):
        import tempfile
        import time
        path = os.path.join(tempfile.mkdtemp(), "trace.jsonl")
        write(path, "")
        # The turn ended between the caller's check and the watch: the re-check
        # under the watch sees it, and nothing waits out the timeout.
        state = {"running": True}

        def still():
            state["running"] = False  # the turn.end landed just before this check
            return state["running"]
        t = time.time()
        team_eval.wait_for_change([path], 10, still)
        self.assertLess(time.time() - t, 1)
        t = time.time()
        team_eval.wait_for_change([path], 0.3, lambda: True)
        self.assertGreaterEqual(time.time() - t, 0.25)

    def test_the_follower_logs_a_kevent_failure_and_closes_its_fds(self):
        import shutil
        import tempfile
        if not hasattr(team_eval.select, "kqueue"):
            self.skipTest("no kqueue")
        home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, home, True)
        logs = []
        f = team_eval.AcpmuxFollower(home, lambda rs: None, log=logs.append)
        f.kq = team_eval.select.kqueue()

        class Broken:
            def __init__(self, kq):
                self.kq = kq

            def control(self, changes, n, timeout=None):
                if changes is None:
                    raise OSError(9, "Bad file descriptor")
                return self.kq.control(changes, n, timeout)

            def close(self):
                self.kq.close()
        f.kq = Broken(f.kq)
        f._run()
        self.assertTrue(any("kevent failed" in m for m in logs), logs)
        self.assertTrue(f.watched)  # the home was watched, then its fd closed
        for fd in f.watched.values():
            with self.assertRaises(OSError):
                os.fstat(fd)
        f.stop()

    def test_the_follower_watches_only_each_sessions_newest_log(self):
        import shutil
        import tempfile
        if not hasattr(team_eval.select, "kqueue"):
            self.skipTest("no kqueue")
        home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, home, True)
        ev = os.path.join(home, "sessions", "s1", "events")
        os.makedirs(ev)
        for n in (1, 2, 3):
            write(os.path.join(ev, f"00000{n}.ndjson"), "")
        f = team_eval.AcpmuxFollower(home, lambda rs: None, log=lambda m: None)
        f.kq = team_eval.select.kqueue()
        self.addCleanup(f.kq.close)
        f._scan()
        files = [p for p in f.watched if p.endswith(".ndjson")]
        self.assertEqual(files, [os.path.join(ev, "000003.ndjson")])
        for fd in f.watched.values():
            os.close(fd)
        f.watched = {}
        f.stop()

    def test_a_live_fd_that_is_not_open_is_dropped(self):
        import tempfile
        d = tempfile.mkdtemp()
        r = subprocess.run([sys.executable, os.path.join(HERE, "team_eval.py"), "run", "--task", "nope", "--arm", "L",
                            "--bins", d, "--repo", d, "--out", d, "--tasks", os.path.join(HERE, "team_eval_tasks.json"),
                            "--live-fd", "97"], capture_output=True, text=True)
        self.assertIn("--live-fd 97 is not open", r.stdout)


class StreamingCampaignTests(unittest.TestCase):
    campaign_with = CampaignOutcomeTests.campaign_with

    def reading(self, req, util):
        import time
        return json.dumps({"at": int(time.time() * 1000), "request_id": req, "7d_utilization": util,
                           "7d_status": "allowed"})

    def fake_run(self, body):
        return ("[ \"$1\" = run ] && { echo 'cmux-ci: step s1 (exclusive)' >&2; " + body +
                f" echo 'TEAM-EVAL {json.dumps(TEAM_EVAL_LINE)}'; exit 0; }}\n")

    def now(self):
        return "$(/usr/bin/python3 -c 'import time; print(int(time.time() * 1000))')"

    def test_a_running_steps_readings_reach_the_ledger_while_it_runs(self):
        body = (f"echo 'TEAM-EVAL-RATELIMIT {self.reading('req_live', 0.6)}'; sleep 1.5; "
                f"echo {self.now()} > {{d}}/ended;")
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            led = self.campaign_with("", 1, run=self.fake_run(body), cap_usd=None)
        live = [r for r in led.readings() if r.get("request_id") == "req_live"]
        self.assertEqual(len(live), 1)
        self.assertEqual(live[0]["source"], "team-eval-x-t-A-1-a1")
        self.assertLess(live[0]["arrived"], int(read(os.path.join(self.d, "ended"))) - 1000)
        self.assertIn("ok", read(os.path.join(self.d, "out", "team-eval-x-t-A-1-a1", "step.log")))
        self.assertIn("TEAM-EVAL-RATELIMIT", read(os.path.join(self.d, "out", "team-eval-x-t-A-1-a1", "step.log")))

    def test_a_step_queued_behind_a_busy_worker_waits_when_a_live_reading_drops_the_headroom(self):
        import contextlib
        import io
        import tempfile
        import time
        # The first step reports 0.9 used (headroom 0.1) while it runs; the second passed the
        # gate before that and waits for m1. Once it has m1 the gate stops it until the low
        # reading is too old and the probe (0.8) lets it go.
        first = os.path.join(tempfile.mkdtemp(), "first")
        body = (f"if mkdir {first} 2>/dev/null; then echo 'TEAM-EVAL-RATELIMIT {self.reading('req_low', 0.9)}';"
                f" sleep 0.5; echo end {self.now()} >> {{d}}/spans; else echo start {self.now()} >> {{d}}/spans; fi;")
        buf = io.StringIO()
        seed = {"at": int(time.time() * 1000), "request_id": "req_seed", "7d_utilization": 0.5, "7d_status": "allowed"}
        orig = team_eval.Ledger.__init__

        def seeded(self, path, cap):
            orig(self, path, cap)
            if not self.readings():
                self.add_readings([seed])
        team_eval.Ledger.__init__ = seeded
        self.addCleanup(setattr, team_eval.Ledger, "__init__", orig)
        with contextlib.redirect_stdout(buf):
            self.campaign_with("", 1, run=self.fake_run(body), arm=["A", "B"], parallel=2, max_concurrent=2,
                               worker=["m1"], headroom_cmd="echo 0.8", headroom_max_age=1.5 / 60, headroom_sleep=1)
        out = buf.getvalue()
        self.assertIn("live reading from team-eval-x-t-A-1-a1: headroom 0.10 is under 0.25", out)
        pause = out.index("is under 0.25: pausing new steps")
        self.assertGreater(pause, out.index("live reading from"))
        self.assertIn("resuming", out[pause:])
        spans = dict(l.split() for l in read(os.path.join(self.d, "spans")).splitlines())
        self.assertGreater(int(spans["start"]) - int(spans["end"]), 900)  # it waited past the pause

    def test_the_pool_lets_max_concurrent_steps_run_whatever_parallel_says(self):
        stamp = "/usr/bin/python3 -c 'import time; print(time.time())'"
        body = f"echo start $({stamp}) >> {{d}}/spans; sleep 1.5; echo end $({stamp}) >> {{d}}/spans;"
        self.campaign_with("", 1, run=self.fake_run(body), task=["t1", "t2"], arm=["A", "B"], parallel=1, max_concurrent=4,
                           cap_usd=None)
        spans = [l.split() for l in read(os.path.join(self.d, "spans")).splitlines()]
        now, most = 0, 0
        for kind, _ in sorted(spans, key=lambda x: (float(x[1]), x[0] == "start")):
            now += 1 if kind == "start" else -1
            most = max(most, now)
        self.assertEqual(most, 4)

    def test_a_stale_or_bad_live_reading_never_stops_the_step_or_frees_its_worker_early(self):
        import contextlib
        import io
        stale = json.dumps({"at": 1000, "request_id": "req_old", "7d_utilization": 0.95, "7d_status": "allowed"})
        body = (f"echo 'TEAM-EVAL-RATELIMIT {stale}'; echo 'TEAM-EVAL-RATELIMIT {{not json'; "
                f"echo 'TEAM-EVAL-RATELIMIT {self.reading('req_new', 0.4)}'; sleep 0.5;")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            led = self.campaign_with("", 1, run=self.fake_run(body), cap_usd=None, worker=["m1"],
                                     headroom_cmd="echo 0.9")
        out = buf.getvalue()
        self.assertIn("a live reading was not taken (JSONDecodeError", out)
        # The reader went on to the end: the later reading and the step's result are in.
        self.assertIn("req_new", [r.get("request_id") for r in led.readings()])
        self.assertEqual(led.tokens()["total"], 26)
        self.assertIn("ok, 26 tokens", out)

    def test_a_stray_byte_in_the_steps_log_never_stops_the_reader(self):
        import contextlib
        import io
        body = (f"printf 'bad \\377 byte\\n'; printf 'err \\377\\n' >&2; "
                f"echo 'TEAM-EVAL-RATELIMIT {self.reading('req_after', 0.4)}';")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            led = self.campaign_with("", 1, run=self.fake_run(body), cap_usd=None)
        self.assertIn("req_after", [r.get("request_id") for r in led.readings()])
        self.assertEqual(led.tokens()["total"], 26)
        self.assertIn("bad \ufffd byte", read(os.path.join(self.d, "out", "team-eval-x-t-A-1-a1", "step.log")))

    def test_a_truncated_team_eval_line_fails_the_attempt_not_the_campaign(self):
        import contextlib
        import io
        run = ("[ \"$1\" = run ] && { echo 'cmux-ci: step s1 (exclusive)' >&2; "
               "echo 'TEAM-EVAL {\"cost_usd\": {\"all\": 3'; exit 0; }\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            led = self.campaign_with("", 1, run=run, arm=["A", "B"], cap_usd=None)
        out = buf.getvalue()
        self.assertEqual(out.count("FAILED: its output did not read (JSONDecodeError"), 2)
        attempts = led.data["attempts"]
        self.assertEqual({a["state"] for a in attempts.values()}, {"unknown"})  # spend unknown: reservation kept
        self.assertTrue(all("did not read" in a["failed"][0] for a in attempts.values()))

    def test_the_default_probe_uses_the_steps_route_and_bad_counts_are_refused(self):
        cmd = team_eval.default_headroom_cmd("http://route:9")
        self.assertTrue(cmd.endswith("headroom_probe.py --base-url http://route:9"), cmd)
        for flag, why in (("--max-concurrent", "at least 1"), ("--headroom-window", "at least 1"),
                          ("--headroom-sleep", "over 0"), ("--headroom-max-age", "over 0")):
            r = subprocess.run([sys.executable, os.path.join(HERE, "team_eval.py"), "campaign", "--name", "x",
                                "--ref", "a" * 40, "--base-url", "u", "--task", "t", "--arm", "A", "--out", "/tmp/x",
                                flag, "0"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, flag)
            self.assertIn(why, r.stderr)


if __name__ == "__main__":
    unittest.main()
