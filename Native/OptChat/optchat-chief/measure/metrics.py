#!/usr/bin/env python3
"""Per-turn numbers of one side's run, from that side's saved raw data.
(This file is the only copy: other parity harnesses load it from here.)

The drivers call this at the end of a run; it can also run again later on the
same directory (after a metrics fix) without repeating the conversation:

  metrics.py reference DIR   raw.json (or turns.json) + frames.jsonl + account.jsonl
  metrics.py chief DIR       raw.json + traces/*.jsonl

Writes DIR/turns.json and updates DIR/run.json.

Windows: a turn owns the time from its send to the next send that is not its
own follow-up. A follow-up (a message sent while its parent turn's subagents
run) gets only its first reply, TTFT and correctness; the parent keeps the
subagents, compactor calls and every reply in its window (an agent may answer
the follow-up and give the combined result in one message).
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scenario  # noqa: E402


def _jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def _windows(results, by_id, end):
    """turn id -> (t0, t1), child id -> parent id, parent id -> [child ids].

    A family is a turn and the messages sent while it runs (`during`). Every
    member's window runs from its own send to the next send outside the family.
    """
    parent = {t["id"]: t["during"] for t in by_id.values() if t.get("during")}
    child = {}
    for c, p in parent.items():
        child.setdefault(p, []).append(c)
    sends = {r["id"]: r["send_ms"] for r in results}
    win = {}
    for r in results:
        root = parent.get(r["id"], r["id"])
        family = {root, *child.get(root, [])}
        t0 = r["send_ms"]
        later = sorted(s for i, s in sends.items() if s > sends.get(root, t0) and i not in family)
        win[r["id"]] = (t0, later[0] if later else end)
    return win, parent, child


def _interrupt(by_id, root, kids, sends, replies, turn_count, stopped, continuation):
    """Per family member: ms from its send to the first later reply that answers it."""
    members = [root] + sorted(kids, key=lambda k: sends.get(k, 0))
    out = {"members": {}, "turns": turn_count, "stopped": stopped, "continuation": continuation}
    for m in members:
        t0 = sends.get(m)
        hit = next(((t - t0) for t, text in replies if t0 is not None and t >= t0 and scenario.check(by_id[m], text)), None)
        out["members"][m] = {"answer_ms": hit, "answered": hit is not None}
    out["all_answered"] = all(v["answered"] for v in out["members"].values())
    out["one_reply_answers_all"] = any(all(scenario.check(by_id[m], text) for m in members) for _, text in replies)
    return out


# Claude Haiku 5.5 list price per MTok (hq-6d 2026-10-09): in, out, write 5m, write 1h, read; above 100K tokens of context.
HAIKU55 = {"lo": (0.10, 0.50, 0.125, 0.20, 0.01), "hi": (0.50, 2.50, 0.625, 1.00, 0.05)}


def haiku_cost(u, prompts=1, ttl="1h"):
    """A node's cost at the Haiku 5.5 table (Claude Code 2.1.287 priced Haiku as Sonnet, 20x too high)."""
    if not u:
        return 0.0
    i, o, w, r = (u.get("input") or 0), (u.get("output") or 0), (u.get("cache_write") or 0), (u.get("cache_read") or 0)
    tier = "hi" if (i + w + r) / max(1, prompts) > 100_000 else "lo"
    pi, po, pw5, pw1, pr = HAIKU55[tier]
    return (i * pi + o * po + w * (pw1 if ttl == "1h" else pw5) + r * pr) / 1e6


def error_class(text):
    """Error note class (catalog owned by the CLI worker): E6 = DNS or connection error, else the text head."""
    t = (text or "").lower()
    if "can't reach the api" in t or "could not resolve" in t or "connection" in t and "error" in t or "enotfound" in t:
        return "E6 connection/DNS"
    if "maximum of 4" in t:
        return "cache marks > 4"
    if "not logged in" in t:
        return "not logged in"
    return (text or "")[:60]


def _check(by_id, tid, text, have):
    return scenario.check(by_id[tid], text) if have else False


# ------------------------------------------------------------------ reference

def reference(out):
    run = json.load(open(os.path.join(out, "run.json")))
    raw_path = os.path.join(out, "raw.json")
    raw = json.load(open(raw_path)) if os.path.exists(raw_path) else {"results": json.load(open(os.path.join(out, "turns.json")))}
    keep = ("id", "kind", "gap", "age", "send_ms", "idle_ms", "timeout", "spent_usd")
    results = [{k: r.get(k) for k in keep} for r in raw["results"]]
    events = _jsonl(os.path.join(out, "frames.jsonl"))
    snaps = _jsonl(os.path.join(out, "account.jsonl"))
    cfg = json.load(open(os.path.expanduser(os.environ.get("CHIEF_PARITY_REFERENCE_CONFIG", "~/.config/chief-parity/reference.json"))))
    ak = cfg["assistant_kind"]
    before = {c["id"] for c in (snaps[0].get("calls") or [])} if snaps else set()
    calls = sorted([c for c in (snaps[-1].get("calls") or []) if c["id"] not in before], key=lambda c: c["at"]) if snaps else []
    by_id = {t["id"]: t for t in scenario.turns(run["scenario"])}
    win, parent, child = _windows(results, by_id, run.get("end") or (results[-1]["idle_ms"] if results else 0))

    def entries(t0, t1):
        return [e for e in events if e.get("$") == "entry" and e.get("agent") is None and e.get("kind") == ak and t0 <= e["t"] <= t1]

    def wait_ms(t0, t1, kind):
        total, on = 0, None
        for e in events:
            if e.get("$") != "state" or e["t"] > t1:
                continue
            if e["t"] < t0:
                on = t0 if e.get("wait") == kind else None
                continue
            if e.get("wait") == kind and on is None:
                on = e["t"]
            elif e.get("wait") != kind and on is not None:
                total += e["t"] - on
                on = None
        return total + (t1 - on if on is not None else 0)

    def hit(c):
        den = c.get("input", 0) + c.get("write", 0) + c.get("read", 0)
        return round(100.0 * c.get("read", 0) / den, 1) if den else None

    for r in results:
        t0, t1 = win[r["id"]]
        evs = [e for e in events if t0 <= e.get("t", 0) <= t1]
        deltas = [e for e in evs if e.get("$") == "delta" and e.get("agent") is None]
        replies = entries(t0, t1)
        is_follow = r["id"] in parent
        if is_follow:
            replies = replies[:1]
        text = "\n".join(e.get("text") or "" for e in replies)
        tcalls = [c for c in calls if t0 <= c["at"] <= t1]
        chat = [c for c in tcalls if c["kind"] == "chat"]
        comp = [] if is_follow else [c for c in tcalls if c["kind"] == "compactor"]
        other = [] if is_follow else [c for c in tcalls if c["kind"] not in ("chat", "compactor")]
        if is_follow:
            chat = chat[:1]
        agents = {}
        if not is_follow:
            for e in evs:
                if e.get("$") != "state":
                    continue
                now = [str(a) for a in (e.get("agents") or [])]
                for a in now:
                    agents.setdefault(a, {"first_ms": e["t"] - t0, "gone_ms": None})
                for name, a in agents.items():
                    if name not in now and a["gone_ms"] is None:
                        a["gone_ms"] = e["t"] - t0
        views = [e for e in events if e.get("$") == "view" and e["t"] <= t0]
        tot = {k: sum(c.get(k, 0) for c in chat) for k in ("input", "write", "read", "output")}
        r.update({
            "ttft_ms": deltas[0]["t"] - t0 if deltas else None,
            "ttft_answer_ms": next((e["t"] - t0 for e in deltas if e.get("kind") == ak), None),
            "turn_ms": (replies[-1]["t"] - t0) if replies else None,
            "task_ms": r["idle_ms"] - 8000 - t0,
            "wait_summaries_ms": wait_ms(t0, t1, "summaries"),
            "wait_model_ms": wait_ms(t0, t1, "model"),
            "tool_calls": sum(1 for e in evs if e.get("$") == "job"),
            "chat_calls": len(chat),
            "first": {k: chat[0].get(k) for k in ("input", "write", "read", "output", "model", "effort")} if chat else None,
            "first_hit": hit(chat[0]) if chat else None,
            "turn_usage": tot,
            "turn_hit": hit(tot) if chat else None,
            "turn_cost_usd": round(sum(c.get("micros", 0) for c in chat) / 1e6, 5),
            "compactor_calls": len(comp),
            # The server keeps no per-call duration: report how long after the turn's last
            # reply the last summary call ended (the settle lag the next turn could see).
            "compactor_span_ms": (comp[-1]["at"] - replies[-1]["t"]) if comp and replies else None,
            "compactor_cost_usd": round(sum(c.get("micros", 0) for c in comp) / 1e6, 5),
            "compactor_hit": hit({k: sum(c.get(k, 0) for c in comp) for k in ("input", "write", "read")}) if comp else None,
            "subagent_calls": len(other),
            "subagent_first_hits": [hit(c) for c in other[:8]],
            "subagent_cost_usd": round(sum(c.get("micros", 0) for c in other) / 1e6, 5),
            "agents": agents,
            "view_lines": views[-1].get("parts") if views else None,
            "view_bytes": views[-1].get("bytes") if views else None,
            "reply": text[:4000],
            "correct": _check(by_id, r["id"], text, replies),
        })
        if r["id"] in child and not is_follow:
            sends = {x["id"]: x["send_ms"] for x in results}
            first_kid = min(sends.get(k, t1) for k in child[r["id"]])
            all_rep = [(e["t"], e.get("text") or "") for e in entries(t0, t1)]
            states = [e for e in evs if e.get("$") == "state"]
            starts = sum(1 for a, b in zip(states, states[1:]) if not a.get("busy") and b.get("busy")) + (1 if states and states[0].get("busy") else 0)
            notes = [e.get("text") or "" for e in evs if e.get("$") in ("note", "error")]
            cont = next((c for c in chat if c["at"] > first_kid), None)
            r["interrupt"] = _interrupt(by_id, r["id"], child[r["id"]], sends, all_rep, starts,
                                        any("Stopped" in n or "No reply" in n for n in notes),
                                        {"read": cont.get("read"), "write": cont.get("write"), "hit": hit(cont)} if cont else None)
            r["interrupt"]["notes"] = notes[:5]
    run["calls"] = len(calls)
    run["cost_usd"] = round(sum(c.get("micros", 0) for c in calls) / 1e6, 4)
    run["cost_by_kind"] = {}
    for c in calls:
        run["cost_by_kind"][c["kind"]] = round(run["cost_by_kind"].get(c["kind"], 0) + c.get("micros", 0) / 1e6, 4)
    if isinstance(run.get("import"), dict):
        first = results[0]["send_ms"] if results else run.get("end", 0)
        imp = [c for c in calls if c["at"] <= first]
        run["import"]["calls"] = len(imp)
        run["import"]["cost_usd"] = round(sum(c.get("micros", 0) for c in imp) / 1e6, 4)
    json.dump(results, open(os.path.join(out, "turns.json"), "w"), indent=1)
    json.dump(run, open(os.path.join(out, "run.json"), "w"), indent=1)
    return results, run


# ------------------------------------------------------------------ chief

def chief(out):
    run = json.load(open(os.path.join(out, "run.json")))
    raw = json.load(open(os.path.join(out, "raw.json")))
    results = raw["results"]
    ev = []
    tdir = os.path.join(out, "traces")
    for name in sorted(os.listdir(tdir)) if os.path.isdir(tdir) else []:
        ev += _jsonl(os.path.join(tdir, name))
    by_id = {t["id"]: t for t in scenario.turns(run["scenario"])}
    win, parent, child = _windows(results, by_id, run.get("end") or (results[-1]["idle_ms"] if results else 0))

    def hit(u):
        if not u:
            return None
        den = (u.get("input") or 0) + (u.get("cache_write") or 0) + (u.get("cache_read") or 0)
        return round(100.0 * (u.get("cache_read") or 0) / den, 1) if den else None

    def add(a, b):
        return {k: (a.get(k) or 0) + (b.get(k) or 0) for k in ("input", "cache_write", "cache_read", "output")}

    out_rows = []
    for r in results:
        t0, t1 = win[r["id"]]
        evs = [e for e in ev if t0 <= e.get("ts", 0) <= t1]
        is_follow = r["id"] in parent
        msgs = sorted([m for m in r.get("msgs", []) if t0 <= m["t"] <= t1], key=lambda m: m["t"])
        if is_follow:
            msgs = msgs[:1]
        text = "\n".join(m["text"] for m in msgs)
        starts = [e for e in evs if e.get("ev") == "turn.start"]
        ends = [e for e in evs if e.get("ev") == "turn.end"]
        if is_follow:
            starts, ends = starts[:1], ends[:1]
        nodes = [] if is_follow else [e for e in evs if e.get("ev") == "node"]
        usage = {}
        for e in ends:
            usage = add(usage, e.get("usage") or {})
        agents = {}
        if not is_follow:
            for e in evs:
                if e.get("ev") == "subagent.start":
                    agents.setdefault(e["id"], {})["first_ms"] = e["ts"] - t0
                elif e.get("ev") == "subagent.done":
                    agents.setdefault(e["id"], {})["gone_ms"] = e["ts"] - t0
                elif e.get("ev") == "subagent.answer":
                    a = agents.setdefault(e["id"], {})
                    a.setdefault("hits", []).append(hit(e.get("usage")))
                    a["cost_usd"] = round(a.get("cost_usd", 0) + (e.get("cost_usd") or 0), 5)
        reports = [] if is_follow else [e for e in evs if e.get("ev") == "spawn.report"]
        row = {k: r.get(k) for k in ("id", "kind", "gap", "age", "send_ms", "idle_ms", "timeout")}
        row.update({
            # No streaming: the first visible text is a whole Chief message.
            "ttft_ms": (msgs[0]["t"] - t0) if msgs else None,
            "ttft_answer_ms": (msgs[0]["t"] - t0) if msgs else None,
            "turn_ms": (msgs[-1]["t"] - t0) if msgs else None,
            "task_ms": r["idle_ms"] - 8000 - t0,
            "wait_summaries_ms": sum(e.get("settle_ms") or 0 for e in starts),
            "turn_starts": len(starts),
            "tool_calls": sum(e.get("tools") or 0 for e in ends),
            "zoom_calls": sum(1 for e in evs if e.get("ev") == "tool" and "zoom" in str(e.get("name"))),
            "chat_calls": sum(e.get("requests") or 0 for e in ends),
            # codex-acp reports only the turn's last request: use it when the first is missing.
            "first": (ends[0].get("first_usage") or ends[0].get("usage")) if ends else None,
            "first_hit": hit(ends[0].get("first_usage") or ends[0].get("usage")) if ends else None,
            "turn_usage": usage,
            "turn_hit": hit(usage),
            "turn_cost_usd": round(sum(e.get("cost_usd") or 0 for e in ends), 5),
            "turn_engine_ms": [e.get("ms") for e in ends],
            "turn_errors": [e.get("error") for e in ends if e.get("error")],
            "model": next((e.get("model") for e in evs if e.get("ev") == "request" and e.get("model")), None),
            "compactor_calls": sum(e.get("prompts") or 1 for e in nodes),
            "compactor_nodes": len(nodes),
            "compactor_failed": sum(1 for e in nodes if e.get("ok") is False),
            "compactor_s": round(sum(e.get("ms") or 0 for e in nodes) / 1000, 2),
            "compactor_cost_usd": round(sum(e.get("cost_usd") or 0 for e in nodes), 5),
            "compactor_cost_haiku_table_usd": round(sum(haiku_cost(e.get("usage"), e.get("prompts") or 1) for e in nodes if "haiku" in str(e.get("model"))), 5),
            "compactor_span_ms": (nodes[-1]["ts"] - msgs[-1]["t"]) if nodes and msgs else None,
            "compactor_hit": hit({k: sum((e.get("usage") or {}).get(k) or 0 for e in nodes) for k in ("input", "cache_write", "cache_read")}) if nodes else None,
            "subagent_calls": len(agents),
            "subagent_first_hits": [h for a in agents.values() for h in a.get("hits", [])[:1]],
            "subagent_cost_usd": round(sum(a.get("cost_usd", 0) for a in agents.values()), 5),
            "agents": agents,
            "spawn_reports_ms": [e.get("ms_since_spawn") for e in reports],
            "view_lines": (starts[0].get("view") or {}).get("lines") if starts else None,
            "view_bytes": (starts[0].get("view") or {}).get("bytes") if starts else None,
            "reply": text[:4000],
            "correct": _check(by_id, r["id"], text, msgs),
        })
        if r["id"] in child and not is_follow:
            sends = {x["id"]: x["send_ms"] for x in results}
            first_kid = min(sends.get(k, t1) for k in child[r["id"]])
            all_rep = [(m["t"], m["text"]) for m in sorted(r.get("msgs", []), key=lambda m: m["t"]) if t0 <= m["t"] <= t1]
            cont = next((e for e in evs if e.get("ev") == "request" and e.get("ts", 0) > first_kid), None)
            errs = [e.get("error") for e in ends if e.get("error")]
            row["interrupt"] = _interrupt(by_id, r["id"], child[r["id"]], sends, all_rep, len(starts),
                                          any(e.get("status") not in (None, "ok") for e in ends) or bool(errs),
                                          {"read": (cont.get("usage") or {}).get("cache_read"), "write": (cont.get("usage") or {}).get("cache_write"),
                                           "hit": hit(cont.get("usage"))} if cont else None)
            row["interrupt"]["statuses"] = [e.get("status") for e in ends]
        out_rows.append(row)
    ends = [e for e in ev if e.get("ev") == "turn.end"]
    nodes = [e for e in ev if e.get("ev") == "node"]
    subs = [e for e in ev if e.get("ev") == "subagent.answer"]
    run["cost_usd"] = round(sum(e.get("cost_usd") or 0 for e in ends + nodes + subs), 4)
    run["cost_by_kind"] = {"chat": round(sum(e.get("cost_usd") or 0 for e in ends), 4),
                           "compactor": round(sum(e.get("cost_usd") or 0 for e in nodes), 4),
                           "subagent": round(sum(e.get("cost_usd") or 0 for e in subs), 4)}
    run["compactor_cost_haiku_table_usd"] = round(sum(haiku_cost(e.get("usage"), e.get("prompts") or 1) for e in nodes if "haiku" in str(e.get("model"))), 4)
    run["engine"] = next(({k: e.get(k) for k in ("engine", "harness", "model", "effort")} for e in ev if e.get("ev") == "turn.start"), None)
    # Error notes from the trace (turn and node errors), by class; a CLI run adds the notes it read.
    notes = dict(run.get("cli_error_notes") or {})
    for e in ends + nodes:
        err = e.get("error")
        if err:
            k = error_class(err.get("prefix") if isinstance(err, dict) else str(err))
            notes[k] = notes.get(k, 0) + 1
    run["error_notes"] = notes
    for row in out_rows:
        row["infra"] = any(error_class(x.get("prefix") if isinstance(x, dict) else str(x)).startswith("E6") for x in row.get("turn_errors") or [])
    json.dump(out_rows, open(os.path.join(out, "turns.json"), "w"), indent=1)
    json.dump(run, open(os.path.join(out, "run.json"), "w"), indent=1)
    return out_rows, run


if __name__ == "__main__":
    side, d = sys.argv[1], sys.argv[2]
    rows, _ = {"reference": reference, "chief": chief}[side](d)
    print(f"{side}: {len(rows)} turns -> {os.path.join(d, 'turns.json')}")
