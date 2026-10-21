#!/usr/bin/env python3
"""Pure parts of team_eval_unii.py (arm C). Run from measure/:
python3 -m unittest test_team_eval_unii"""
import os
import tempfile
import unittest

import team_eval
import team_eval_unii as tu


class Pick(unittest.TestCase):
    def test_api_ids_map_to_unii_labels(self):
        self.assertEqual(tu.unii_pick("claude-opus-5-5", "medium"), "claude-api:opus-5.5:medium:slow")
        self.assertEqual(tu.unii_pick("claude-haiku-5-5", "low"), "claude-api:haiku-5.5:low:slow")
        self.assertEqual(tu.unii_pick("sonnet-5.5", "high"), "claude-api:sonnet-5.5:high:slow")

    def test_defaults(self):
        self.assertEqual(tu.unii_pick("", ""), "claude-api:opus-5.5:medium:slow")

    def test_models_unii_lacks_fail_loudly(self):
        with self.assertRaises(SystemExit):
            tu.unii_pick("claude-sonnet-5", "medium")
        with self.assertRaises(SystemExit):
            tu.unii_pick("claude-opus-5-5", "turbo")


class Cost(unittest.TestCase):
    def test_opus_list_prices(self):
        # $5 in, $25 out, $0.5 cache read, $6.25 cache write 5m, per MTok.
        u = {"input_tokens": 1_000_000, "output_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000,
             "cache_creation_input_tokens": 1_000_000}
        self.assertAlmostEqual(tu.usage_cost("claude-opus-5-5", u), 5 + 25 + 0.5 + 6.25)

    def test_cache_write_split_by_ttl(self):
        u = {"cache_creation_input_tokens": 2_000_000,
             "cache_creation": {"ephemeral_5m_input_tokens": 1_000_000, "ephemeral_1h_input_tokens": 1_000_000}}
        self.assertAlmostEqual(tu.usage_cost("claude-opus-5-5", u), 6.25 + 10)

    def test_web_searches(self):
        u = {"input_tokens": 0, "server_tool_use": {"web_search_requests": 3}}
        self.assertAlmostEqual(tu.usage_cost("claude-haiku-5-5", u), 0.03)

    def test_unpriced_model_takes_its_family_and_says_so(self):
        price, note = tu.price_of("claude-sonnet-5-5")
        self.assertEqual(price, tu.PRICES["claude-sonnet-5"])
        self.assertIn("claude-sonnet-5", note)
        self.assertIsNone(tu.price_of("claude-opus-5-5")[1])

    def test_usage_folds_as_anthropic_ts(self):
        use = {}
        tu.merge_usage(use, {"input_tokens": 10, "cache_read_input_tokens": 500, "output_tokens": 1})
        tu.merge_usage(use, {"output_tokens": 42, "input_tokens": None})
        self.assertEqual(use, {"input_tokens": 10, "cache_read_input_tokens": 500, "output_tokens": 42})

    def test_split_by_what_the_request_served(self):
        recs = [{"kind": "turn", "cost_usd": 1.0}, {"kind": "turn", "cost_usd": 0.5}, {"kind": "subagent", "cost_usd": 2.0},
                {"kind": "compactor", "cost_usd": 0.25}, {"kind": "count", "cost_usd": 0.0}]
        self.assertEqual(tu.cost_split(recs), {"turns": 1.5, "subagents": 2.0, "compactor": 0.25, "all": 3.75})

    def test_classify(self):
        self.assertEqual(tu.classify({"system": [{"text": "x"}]}), "compactor")
        self.assertEqual(tu.classify({"system": [{"text": "You are Unii"}], "tools": [{"name": "spawn"}]}), "turn")
        self.assertEqual(tu.classify({"system": [{"text": tu.SUB_HEAD + ", an AI"}], "tools": [{"name": "shell"}]}), "subagent")


class Sse(unittest.TestCase):
    def test_complete_events_and_rest(self):
        buf = 'event: message_start\ndata: {"type":"message_start"}\n\ndata: {"type":"ping"}\ndata: {"ty'
        evs, rest = tu.sse_events(buf)
        self.assertEqual([e["type"] for e in evs], ["message_start", "ping"])
        self.assertEqual(rest, 'data: {"ty')


class Messages(unittest.TestCase):
    RECS = [
        {"kind": "unii", "text": "Hello! This is UniiChat.", "i": 0},
        {"kind": "user", "text": "eval@example.com", "i": 1},
        {"kind": "unii", "text": "You're in!", "i": 2},
        {"kind": "user", "text": "do the ", "i": 3, "more": True},
        {"kind": "user", "text": "task", "i": 4, "act": "te-brief-1"},
        {"act": "te-x", "ans": {}},
        {"kind": "tool", "text": "shell {\"command\":\"ls\"}", "i": 5},
        {"kind": "echo", "text": "README.md", "i": 6},
        {"kind": "unii", "text": "On it.", "i": 7},
        {"kind": "work", "text": "[FireAnt] report: done", "i": 8},
        {"kind": "unii", "text": "  ", "i": 9},
        {"kind": "unii", "text": "Done.", "i": 10},
    ]

    def test_chief_shape(self):
        msgs, arrivals = tu.unii_messages(self.RECS, {4: 1000, 7: 2000, 10: 3000}, after=2)
        self.assertEqual([(m["id"], m["author"], team_eval.text_of(m)) for m in msgs],
                         [("u3", "user_local", "do the task"), ("u7", "agent_mux", "On it."), ("u10", "agent_mux", "Done.")])
        self.assertEqual([m["seq"] for m in msgs], [1, 2, 3])
        self.assertEqual(msgs[0]["client_msg_id"], "te-brief-1")
        self.assertEqual(msgs[1]["parts"], [{"type": "text", "text": "On it."}])
        self.assertEqual(arrivals, {"u3": 1000, "u7": 2000, "u10": 3000})

    def test_timeline_reads_it(self):
        msgs, arrivals = tu.unii_messages(self.RECS, {4: 1000, 7: 2500, 10: 3000}, after=2)
        tl = team_eval.timeline({"brief": 1000}, msgs, arrivals)
        self.assertEqual(tl["brief"]["first_reply_ms"], 1500)
        self.assertFalse(tl["brief"]["first_reply_is_receipt"])

    def test_turns_are_rises_of_busy(self):
        st = [{"busy": False}, {"busy": True}, {"busy": True}, {"busy": False}, {"busy": True}, {"busy": False}]
        self.assertEqual(tu.turns_of(st), 2)


class Patch(unittest.TestCase):
    def test_both_urls_go_to_the_proxy(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "Anthropic.ts")
        open(p, "w").write('const COUNT = "https://api.anthropic.com/v1/messages/count_tokens";\n'
                           'url : "https://api.anthropic.com/v1/messages",\n')
        self.assertEqual(tu.patch_source(d, "http://127.0.0.1:9/"), 2)
        text = open(p).read()
        self.assertNotIn("api.anthropic.com", text)
        self.assertIn('"http://127.0.0.1:9/v1/messages"', text)


if __name__ == "__main__":
    unittest.main()
