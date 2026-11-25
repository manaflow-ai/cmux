#!/usr/bin/env python3
"""Chief latency numbers of one scratch-Chief run, and a before/after table of two.

The harness of the Chief latency lane (scripts/measure/chief-latency.sh runs it at two refs, on
one worker, back to back). It reads the same trace fields as Lucas's measurement of a live
Chief (shared plan "Chief turns are slow and large", 2026-11-23; chief_trace_stats.py): the
host's own trace ($MUX_HOME/optchat/traces, copied into the run dir by chief_driver.py) and the
driver's turns.json (metrics.py: what the person saw, from the daemon).

  chief_latency.py summary RUN_DIR [RUN_DIR...] [--label NAME] [--ref SHA] [--out FILE] [--md FILE]
      one ref's numbers as JSON, its rounds pooled (printed, and written to FILE)
  chief_latency.py compare BEFORE.json AFTER.json [--md FILE] [--json FILE]
      the before/after markdown table a PR body pastes, and both summaries in one JSON

Numbers (every Chief turn the host ran: person turns and host-started ones):
  first_request_tokens   input + cache_read + cache_write of each turn's first request (p50, p90, mean)
  request_tokens         the same for every model request of a Chief turn
  requests_per_turn      model requests per Chief turn
  ttft_ms                the host's time to first token (session start + first request's first token)
  turn_ms                the host's turn time (wake to the turn's end)
  felt_first_reply_ms    the person's send to the first Chief message on screen (driver clock)
  felt_last_reply_ms     the person's send to the last Chief message of that ask
  cold_share             turns whose first request wrote more to the cache than it read
  host_started_turns     turns with no person message (a subagent report, a host note)
  rerendered_turns       turns that froze a new view (layout.delta.rendered); cold ones among them
  refused_sends          send calls the host refused (the 45-word limit, the reply ledger)
  cost_usd               the API-equivalent cost of the Chief's own turns
"""
import argparse
import json
import os
import sys


def _jsonl(path):
    out = []
    with open(path) as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def pct(values, p):
    a = sorted(v for v in values if isinstance(v, (int, float)))
    if not a:
        return None
    return a[min(len(a) - 1, int(p * len(a)))]


def dist(values):
    a = [v for v in values if isinstance(v, (int, float))]
    return {"n": len(a), "p50": pct(a, 0.5), "p90": pct(a, 0.9),
            "mean": round(sum(a) / len(a), 1) if a else None}


def prompt_tokens(u):
    if not u:
        return None
    return (u.get("input") or 0) + (u.get("cache_read") or 0) + (u.get("cache_write") or 0)


def is_cold(u):
    return bool(u) and (u.get("cache_write") or 0) > (u.get("cache_read") or 0)


def trace_events(run_dir):
    tdir = os.path.join(run_dir, "traces")
    ev = []
    for name in sorted(os.listdir(tdir)) if os.path.isdir(tdir) else []:
        if name.endswith(".jsonl"):
            ev += _jsonl(os.path.join(tdir, name))
    return ev


def _collect(run_dir):
    ev = trace_events(run_dir)
    if not ev:
        raise SystemExit(f"{run_dir}: no trace events (traces/*.jsonl)")
    starts = {e.get("turn"): e for e in ev if e.get("ev") == "turn.start" and e.get("turn")}
    ends = [e for e in ev if e.get("ev") == "turn.end" and e.get("turn")]
    keys = {e["turn"] for e in ends}
    requests = [e for e in ev if e.get("ev") == "request" and e.get("turn") in keys]
    tools = [e for e in ev if e.get("ev") == "tool" and e.get("turn") in keys]
    per_turn = []
    for i, e in enumerate(ends):
        s = starts.get(e["turn"]) or {}
        sources = s.get("sources") or []
        delta = ((s.get("layout") or {}).get("delta") or {})
        first = e.get("first_usage") or e.get("usage")
        per_turn.append({
            "turn": e["turn"], "round": os.path.basename(os.path.normpath(run_dir)), "status": e.get("status"),
            "sources": sources, "host_started": "human" not in sources,
            "rerendered": bool(delta.get("rendered")), "round_first": i == 0,
            "first_tokens": prompt_tokens(first), "first_usage": first, "cold": is_cold(first),
            "requests": e.get("requests"), "ttft_ms": e.get("ttft_ms"), "ms": e.get("ms"),
            "headers_ms": e.get("headers_ms"), "cost_usd": e.get("cost_usd"),
            "view_bytes": (s.get("view") or {}).get("bytes"), "system_bytes": (s.get("system") or {}).get("bytes"),
        })
    felt = []
    tj = os.path.join(run_dir, "turns.json")
    if os.path.exists(tj):
        felt = json.load(open(tj))
        felt = felt.get("turns", felt) if isinstance(felt, dict) else felt
    run = {}
    rj = os.path.join(run_dir, "run.json")
    if os.path.exists(rj):
        run = json.load(open(rj))
    return per_turn, requests, tools, felt, run


def summary(run_dirs, label=None, ref=None):
    """Pool one or more run directories (rounds of one ref) into one summary."""
    if isinstance(run_dirs, str):
        run_dirs = [run_dirs]
    per_turn, requests, tools, felt, run = [], [], [], [], {}
    for d in run_dirs:
        p, r, t, f, rn = _collect(d)
        per_turn += p
        requests += r
        tools += t
        felt += f
        run = run or rn
    ok = [t for t in per_turn if t["first_usage"]]
    cold = [t for t in ok if t["cold"]]
    rer = [t for t in ok if t["rerendered"]]
    sends = [t for t in tools if str(t.get("name", "")).split("__")[-1] in ("send", "reply")]
    refused = [t for t in sends if t.get("ok") is False]
    tool_ms = {}
    for t in tools:
        tool_ms.setdefault(str(t.get("name", "")).split("__")[-1], []).append(t.get("ms"))
    out = {
        "label": label, "ref": ref or run.get("build"), "rounds": len(run_dirs), "claude_code_version": run.get("claude_code_version"),
        "engine": run.get("engine"),
        "asks": len(felt), "asks_timed_out": sum(1 for r in felt if r.get("timeout")),
        "asks_correct": sum(1 for r in felt if r.get("correct") is True),
        "asks_checked": sum(1 for r in felt if r.get("correct") is not None),
        "chief_turns": len(per_turn),
        "turn_statuses": {s: sum(1 for t in per_turn if t["status"] == s) for s in sorted({t["status"] for t in per_turn}, key=str)},
        "host_started_turns": sum(1 for t in per_turn if t["host_started"]),
        "first_request_tokens": dist([t["first_tokens"] for t in ok]),
        "request_tokens": dist([prompt_tokens(r.get("usage")) for r in requests]),
        "requests_per_turn": dist([t["requests"] for t in per_turn]),
        "ttft_ms": dist([t["ttft_ms"] for t in per_turn]),
        "ttft_ms_warm": dist([t["ttft_ms"] for t in ok if not t["cold"]]),
        "ttft_ms_cold": dist([t["ttft_ms"] for t in cold]),
        "turn_ms": dist([t["ms"] for t in per_turn]),
        "felt_first_reply_ms": dist([r.get("ttft_ms") for r in felt]),
        "felt_last_reply_ms": dist([r.get("turn_ms") for r in felt]),
        "cold_turns": len(cold), "cold_share": round(len(cold) / len(ok), 3) if ok else None,
        "cold_turns_after_first": sum(1 for t in cold if not t["round_first"]),
        "rerendered_turns": len(rer), "rerendered_cold": sum(1 for t in rer if t["cold"]),
        "sends": len(sends), "refused_sends": len(refused),
        "tool_ms": {k: dist(v) for k, v in sorted(tool_ms.items())},
        "cost_usd": round(sum(t["cost_usd"] or 0 for t in per_turn), 4),
        "system_bytes": pct([t["system_bytes"] for t in per_turn], 0.5),
        "view_bytes_last": next((t["view_bytes"] for t in reversed(per_turn) if t["view_bytes"]), None),
        "per_turn": per_turn,
        "per_ask": [{k: r.get(k) for k in ("id", "kind", "ttft_ms", "turn_ms", "turn_starts", "chat_calls", "first_hit", "correct", "timeout")}
                    for r in felt],
    }
    return out


ROWS = [
    ("First request of a turn, input tokens (p50)", "first_request_tokens", "p50", ""),
    ("First request of a turn, input tokens (p90)", "first_request_tokens", "p90", ""),
    ("Every request, input tokens (p50)", "request_tokens", "p50", ""),
    ("Requests per Chief turn (mean)", "requests_per_turn", "mean", ""),
    ("First token, host (p50)", "ttft_ms", "p50", "ms"),
    ("First token, warm turns (p50)", "ttft_ms_warm", "p50", "ms"),
    ("First token, cold turns (p50)", "ttft_ms_cold", "p50", "ms"),
    ("Turn time, host (p50)", "turn_ms", "p50", "ms"),
    ("Turn time, host (p90)", "turn_ms", "p90", "ms"),
    ("Send to first reply, felt (p50)", "felt_first_reply_ms", "p50", "ms"),
    ("Send to last reply, felt (p50)", "felt_last_reply_ms", "p50", "ms"),
    ("Send to last reply, felt (p90)", "felt_last_reply_ms", "p90", "ms"),
]
COUNTS = [
    ("Cold turns (first request wrote more cache than it read)", "cold_turns", ""),
    ("Cold share", "cold_share", "ratio"),
    ("Chief turns (host-started)", None, ""),
    ("View re-renders (cold)", None, ""),
    ("Refused sends", "refused_sends", ""),
    ("Asks correct", None, ""),
    ("Chief turn cost, API-equivalent", "cost_usd", "usd"),
]


def _fmt(v, unit=""):
    if v is None:
        return "-"
    if unit == "ms":
        return f"{v / 1000:.1f} s"
    if unit == "usd":
        return f"${v:,.2f}"
    if unit == "ratio":
        return f"{100 * v:.0f}%"
    if isinstance(v, float):
        return f"{v:,.2f}" if v < 100 else f"{v:,.0f}"
    return f"{v:,}"


def _delta(a, b):
    if not isinstance(a, (int, float)) or not isinstance(b, (int, float)) or not a:
        return ""
    return f"{100 * (b - a) / a:+.0f}%"


def _count(s, label):
    if label.startswith("Chief turns"):
        return f"{s['chief_turns']} ({s['host_started_turns']})"
    if label.startswith("View re-renders"):
        return f"{s['rerendered_turns']} ({s['rerendered_cold']})"
    if label.startswith("Asks correct"):
        return f"{s['asks_correct']}/{s['asks_checked']}"
    return None


def table(a, b):
    sa, sb = (a.get("ref") or "")[:10], (b.get("ref") or "")[:10]
    lines = [f"| Chief latency (scenario `latency`, {a['asks']} asks) | before `{sa}` | after `{sb}` | change |",
             "|---|---|---|---|"]
    for title, key, stat, unit in ROWS:
        va, vb = (a.get(key) or {}).get(stat), (b.get(key) or {}).get(stat)
        lines.append(f"| {title} | {_fmt(va, unit)} | {_fmt(vb, unit)} | {_delta(va, vb)} |")
    for title, key, unit in COUNTS:
        if key is None:
            lines.append(f"| {title} | {_count(a, title)} | {_count(b, title)} | |")
        else:
            lines.append(f"| {title} | {_fmt(a.get(key), unit)} | {_fmt(b.get(key), unit)} | {_delta(a.get(key), b.get(key)) if unit != 'ratio' else ''} |")
    lines.append("")
    lines.append(f"{a.get('rounds') or 1} round(s) each, same worker, alternating before/after; Claude Code {a.get('claude_code_version') or '?'}. "
                 "Tokens are input + cache read + cache write. Cold share counts the run's first turn too (always cold).")
    return "\n".join(lines) + "\n"


def single_table(s):
    lines = [f"| Chief latency (scenario `latency`, {s['asks']} asks) | `{(s.get('ref') or '')[:10]}` |", "|---|---|"]
    for title, key, stat, unit in ROWS:
        lines.append(f"| {title} | {_fmt((s.get(key) or {}).get(stat), unit)} |")
    for title, key, unit in COUNTS:
        lines.append(f"| {title} | {_count(s, title) if key is None else _fmt(s.get(key), unit)} |")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summary")
    s.add_argument("run_dir", nargs="+", help="one directory per round of one ref (chief_driver.py --out)")
    s.add_argument("--label")
    s.add_argument("--ref")
    s.add_argument("--out")
    s.add_argument("--md")
    c = sub.add_parser("compare")
    c.add_argument("before")
    c.add_argument("after")
    c.add_argument("--md")
    c.add_argument("--json")
    o = ap.parse_args()
    if o.cmd == "summary":
        res = summary(o.run_dir, o.label, o.ref)
        if o.out:
            json.dump(res, open(o.out, "w"), indent=1)
        if o.md:
            open(o.md, "w").write(single_table(res))
        print(json.dumps({k: v for k, v in res.items() if k not in ("per_turn", "per_ask")}))
        return
    a, b = json.load(open(o.before)), json.load(open(o.after))
    md = table(a, b)
    if o.md:
        open(o.md, "w").write(md)
    if o.json:
        json.dump({"before": a, "after": b}, open(o.json, "w"), indent=1)
    sys.stdout.write(md)


if __name__ == "__main__":
    main()
