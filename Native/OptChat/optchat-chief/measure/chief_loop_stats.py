#!/usr/bin/env python3
"""Where a real Chief's turns, money and messages go: read-only, no model, seconds.

usage: chief_loop_stats.py [--traces DIR] [--since 2026-11-12] [--until 2026-11-19] [--json]

Reads the day files of an optchat `traces/` dir (default
~/.cmux/chief/default/optchat/traces) and prints, per day and for the window:

- turns by trigger: human (a person's message), report (a subagent's report),
  untold (the outcome-ledger retry), wake (a sleep/wake note), watch, other note;
- cost (USD) and tool calls per trigger;
- Chief posts (send/reply) per person message, and refused posts (too long);
- subagent reports: count, interim share (a report that says it is not done:
  still running, waiting, will report, not landed yet), reports per subagent;
- report -> told: time from a subagent's report to the first Chief post that
  names it; posts per subagent per day (the same outcome told again);
- nudges: resume, land follow-up and stuck events.

It never prints message text, only counts, so its output can go in a plan.
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import statistics
import sys

INTERIM = re.compile(
    r"no (pass/fail )?result yet|still (running|compiling|queued|waiting|in progress)|"
    r"\bwaiting (on|for)\b|will report|i will report|monitor will|not landed yet|"
    r"nothing (new )?(has )?landed|is queued|are queued|keeps? (watching|waiting)|"
    r"\bpending\b|not (done|finished) yet",
    re.I,
)
AID = re.compile(r"\ba(\d{2,5})\b")
POST_TOOLS = {"mcp__optchat__send", "mcp__optchat__reply", "send", "reply"}


def pct(a, p):
    a = sorted(x for x in a if x is not None)
    if not a:
        return None
    return a[min(len(a) - 1, int(p * len(a)))]


def trigger(start):
    src = start.get("sources") or []
    if "human" in src:
        return "human"
    texts = [(m.get("text") or m.get("prefix") or "") for m in start.get("messages") or []]
    if any(t.startswith("[untold]") for t in texts):
        return "untold"
    if "subagents" in src:
        return "report"
    if any(t.startswith("[wake]") for t in texts):
        return "wake"
    if any(t.startswith("[watch") for t in texts):
        return "watch"
    if any(t.startswith("[no reply]") for t in texts):
        return "no_reply"
    if any(re.match(r"\[a\d+\]", t) for t in texts):
        return "report"
    return "other"


def load(paths):
    for p in paths:
        with open(p, errors="replace") as f:
            for line in f:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue


def day_of(ts):
    return dt.datetime.fromtimestamp(ts / 1000).strftime("%Y-%m-%d")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--traces", default=os.path.expanduser("~/.cmux/chief/default/optchat/traces"))
    ap.add_argument("--since", default=None, help="first day, YYYY-MM-DD (default: 7 days ago)")
    ap.add_argument("--until", default=None, help="last day, YYYY-MM-DD (inclusive)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    since = a.since or (dt.date.today() - dt.timedelta(days=7)).isoformat()
    until = a.until or dt.date.today().isoformat()
    files = sorted(
        p for p in glob.glob(os.path.join(a.traces, "*.jsonl"))
        if since <= os.path.basename(p)[:10] <= until
    )

    starts = {}
    ends = {}
    tools_by_turn = collections.defaultdict(list)
    reports = []  # (ts, id, interim)
    done_events = []
    posts = []  # (ts, ids, turn)
    refused = collections.Counter()
    nudges = collections.Counter()
    humans = collections.Counter()
    for d in load(files):
        ev = d.get("ev")
        ts = d.get("ts") or 0
        if ev == "turn.start":
            starts[d.get("turn")] = d
        elif ev == "turn.end":
            ends[d.get("turn")] = d
        elif ev == "tool" and not d.get("subagent"):
            tools_by_turn[d.get("turn")].append(d)
            if d.get("name") in POST_TOOLS and d.get("ok"):
                text = json.dumps(d.get("args") or {})
                posts.append((ts, set(AID.findall(text)), d.get("turn")))
        elif ev == "subagent.done":
            rep = d.get("report") or {}
            text = rep.get("text") or rep.get("prefix") or ""
            interim = (not d.get("landed")) and bool(INTERIM.search(text))
            done_events.append(d)
            reports.append((ts, (d.get("id") or "").lstrip("a"), interim, d.get("landed")))
        elif ev == "chief.reply_too_long":
            refused[day_of(ts)] += 1
        elif ev in ("subagent.resume", "subagent.land_followup", "subagent.stuck"):
            nudges[(day_of(ts), ev)] += 1
        elif ev == "usage.message" and d.get("from") == "human":
            humans[day_of(ts)] += 1

    days = sorted({day_of(s.get("ts") or 0) for s in starts.values()})
    rows = {}
    tot = collections.defaultdict(lambda: collections.defaultdict(float))
    for turn, s in starts.items():
        e = ends.get(turn) or {}
        k = trigger(s)
        day = day_of(s.get("ts") or 0)
        r = rows.setdefault(day, collections.defaultdict(lambda: collections.defaultdict(float)))
        cost = e.get("cost_usd") or 0.0
        ntools = len(tools_by_turn.get(turn, []))
        nposts = sum(1 for t in tools_by_turn.get(turn, []) if t.get("name") in POST_TOOLS and t.get("ok"))
        for bucket in (r[k], r["all"], tot[k], tot["all"]):
            bucket["turns"] += 1
            bucket["cost"] += cost
            bucket["tools"] += ntools
            bucket["posts"] += nposts
            bucket["silent"] += 1 if nposts == 0 else 0
            bucket["ms"] += e.get("ms") or 0

    # report -> first post naming it
    posts.sort()
    lag = []
    told_never = 0
    for ts, aid, interim, landed in reports:
        if not aid:
            continue
        first = next((p for p in posts if p[0] >= ts and aid in p[1]), None)
        if first is None:
            told_never += 1
        else:
            lag.append((first[0] - ts) / 1000)
    per_sub_posts = collections.Counter()
    for ts, ids, _ in posts:
        for i in ids:
            per_sub_posts[(day_of(ts), i)] += 1
    per_sub_reports = collections.Counter(r[1] for r in reports)

    out = {
        "window": [since, until],
        "files": len(files),
        "days": {},
        "totals": {k: dict(v) for k, v in tot.items()},
        "reports": {
            "count": len(reports),
            "interim": sum(1 for r in reports if r[2]),
            "landed": sum(1 for r in reports if r[3]),
            "per_subagent_p50": pct(list(per_sub_reports.values()), 0.5),
            "per_subagent_p90": pct(list(per_sub_reports.values()), 0.9),
            "subagents": len(per_sub_reports),
        },
        "report_to_told_s": {
            "p50": pct(lag, 0.5), "p90": pct(lag, 0.9), "told": len(lag), "never": told_never,
        },
        "posts_per_subagent_day": {
            "p50": pct(list(per_sub_posts.values()), 0.5),
            "p90": pct(list(per_sub_posts.values()), 0.9),
            "max": max(per_sub_posts.values()) if per_sub_posts else None,
            "told_3plus": sum(1 for v in per_sub_posts.values() if v >= 3),
            "pairs": len(per_sub_posts),
        },
        "refused_too_long": sum(refused.values()),
        "nudges": {ev: sum(n for (d, e), n in nudges.items() if e == ev)
                   for ev in ("subagent.resume", "subagent.land_followup", "subagent.stuck")},
        "person_messages": sum(humans.values()),
    }
    for day in days:
        r = rows.get(day, {})
        out["days"][day] = {
            k: {"turns": int(v["turns"]), "cost": round(v["cost"], 2), "tools": int(v["tools"]),
                "posts": int(v["posts"]), "silent": int(v["silent"])}
            for k, v in r.items()
        }
        out["days"][day]["refused"] = refused.get(day, 0)
        out["days"][day]["person_messages"] = humans.get(day, 0)

    if a.json:
        json.dump(out, sys.stdout, indent=1, default=float)
        print()
        return
    kinds = ["human", "report", "untold", "wake", "watch", "no_reply", "other", "all"]
    print(f"Chief loop stats {since}..{until} ({len(files)} day files)")
    print(f"{'day':<11}" + "".join(f"{k:>9}" for k in kinds) + f"{'cost$':>9}{'posts':>7}{'refusd':>7}")
    for day in days:
        r = out["days"][day]
        print(f"{day:<11}" + "".join(f"{r.get(k, {}).get('turns', 0):>9}" for k in kinds)
              + f"{r['all']['cost']:>9.0f}{r['all']['posts']:>7}{r['refused']:>7}")
    print()
    print(f"{'trigger':<10}{'turns':>7}{'share':>7}{'cost$':>9}{'$/turn':>8}{'tools/t':>8}{'silent':>8}{'s/turn':>8}")
    T = tot["all"]["turns"] or 1
    for k in kinds:
        v = tot.get(k)
        if not v:
            continue
        n = v["turns"]
        print(f"{k:<10}{int(n):>7}{n / T:>7.0%}{v['cost']:>9.0f}{v['cost'] / n:>8.2f}"
              f"{v['tools'] / n:>8.1f}{v['silent'] / n:>8.0%}{v['ms'] / n / 1000:>8.1f}")
    rp = out["reports"]
    print()
    print(f"subagent reports {rp['count']} from {rp['subagents']} subagents; interim (not done) "
          f"{rp['interim']} ({rp['interim'] / max(1, rp['count']):.0%}); landed {rp['landed']}; "
          f"per subagent p50 {rp['per_subagent_p50']} p90 {rp['per_subagent_p90']}")
    rt = out["report_to_told_s"]
    print(f"report -> first post naming it: p50 {rt['p50']} s, p90 {rt['p90']} s; never {rt['never']}")
    ps = out["posts_per_subagent_day"]
    print(f"posts naming one subagent per day: p50 {ps['p50']} p90 {ps['p90']} max {ps['max']}; "
          f"(subagent, day) pairs told 3+ times {ps['told_3plus']}/{ps['pairs']}")
    print(f"posts refused as too long {out['refused_too_long']}; person messages {out['person_messages']}")
    print(f"nudges {out['nudges']}")


if __name__ == "__main__":
    main()
