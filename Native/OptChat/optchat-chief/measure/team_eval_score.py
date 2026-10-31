#!/usr/bin/env python3
"""Score coordinator-mode eval runs (team_eval.py outputs) with a model judge.

usage: team_eval_score.py OUT_DIR... [--tasks FILE] [--judge claude] [--model M] [--json FILE]
Each OUT_DIR is one run's `out/` (unpacked from the step's out.tgz). For
each run the judge answers three questions, each in its own call:
  replies   for the brief and each follow-up, the first Chief message that
            usefully addresses it and the first that reports acting on it
            (sees the transcript with times; not blind)
  checklist every item (the brief's asks, then each follow-up's `adds`) met
            or not (sees the transcript and the final diff; not blind)
  quality   1 to 5 for correct, complete, in scope (sees only the brief, the
            follow-ups and the diff: blind to the arm)
Prints one line per run (TEAM-EVAL-SCORE) and one per arm (TEAM-EVAL-ARM:
the stall numbers of all its runs' messages pooled, and its tokens, with
dollars second). The judge is `claude -p` on this machine (the person's
own login); nothing here starts a Chief.
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import team_eval  # noqa: E402

MAX_DIFF = 60000


def judge(prompt, opts):
    r = subprocess.run([opts.judge, "-p", "--model", opts.model, "--output-format", "text"], input=prompt,
                       capture_output=True, text=True, timeout=600)
    m = re.search(r"\{.*\}", r.stdout, re.S)
    if not m:
        raise RuntimeError(f"judge gave no JSON: {r.stdout[-400:]} {r.stderr[-400:]}")
    return json.loads(m.group(0))


def transcript(run, conv):
    arrivals = conv["arrivals"]
    t0 = run["sent"]["brief"]
    lines = []
    for m in sorted(conv["messages"], key=lambda m: m.get("seq", 0)):
        who = "PERSON" if m.get("author") == "user_local" else ("DESK" if team_eval.is_desk(m) else "CHIEF")
        t = (arrivals.get(m["id"], t0) - t0) / 1000
        lines.append(f"[{m['id']} +{t:.0f}s {who}] {team_eval.text_of(m)[:3000]}")
    return "\n".join(lines)


def excluded(run):
    """Why a run is not a result (it did not pass the step, or ran another
    model or effort than the pin), or None."""
    why = list(run.get("failed") or [])
    if run.get("ok") is None:
        why.append("no ok in run.json (not packed by the step)")
    if not (run.get("pin") or {}).get("ok"):
        why.append(f"pin: {(run.get('pin') or {}).get('bad')}")
    return why or None


def run_usd(run):
    """The run's dollars (the higher of the trace's and the live meter's)."""
    return max([v for v in (run.get("cost_usd", {}).get(k) for k in ("all", "live")) if v is not None] or [None])


def by_arm(rows):
    """One row per arm from the scored runs (excluded ones apart): the
    stall summary of every message of its runs, pooled, and its tokens."""
    arms = {}
    for row in rows:
        a = arms.setdefault(row.get("arm"), {"arm": row.get("arm"), "runs": 0, "excluded": 0, "msgs": [], "tok": [], "usd": 0.0})
        if row.get("excluded"):
            a["excluded"] += 1
            continue
        a["runs"] += 1
        a["msgs"] += list((row.get("stall_messages") or {}).values())
        a["tok"].append(row.get("tokens"))
        a["usd"] += row.get("cost_usd") or 0
    out = []
    for a in arms.values():
        out.append({"arm": a["arm"], "runs": a["runs"], "excluded": a["excluded"],
                    "stall": team_eval.stall_summary(a.pop("msgs")),
                    "tokens": team_eval.sum_tokens(a.pop("tok")),
                    "tokens_unknown": sum(1 for r in rows if r.get("arm") == a["arm"] and not r.get("excluded") and not r.get("tokens")),
                    "cost_usd": round(a["usd"], 2)})
    return out


def score(out, tasks, opts):
    def load(name):
        with open(os.path.join(out, name)) as f:
            return json.load(f) if name.endswith(".json") else f.read()

    run = load("run.json")
    why = excluded(run)
    if why:
        return {"task": run.get("task"), "arm": run.get("arm"), "excluded": why}
    conv = load("conversation.json")
    diff = load("diff.patch")
    checks = load("checks.json") if os.path.exists(os.path.join(out, "checks.json")) else {}
    task = next(t for t in tasks if t["id"] == run["task"])
    prompts = [("brief", task["brief"])] + [(f["id"], f["text"]) for f in task["followups"] if f["id"] in run["sent"]]
    tx = transcript(run, conv)
    cut = diff if len(diff) <= MAX_DIFF else diff[:MAX_DIFF] + "\n[diff cut]"

    replies = judge(
        "You judge an AI assistant's chat. Below is the transcript (message id, seconds since the first "
        "message, sender). For each PERSON prompt listed, give the id of the first CHIEF or DESK message that "
        "usefully addresses it (a plan, an answer or a result; a bare 'got it' or a busy notice is not useful), "
        "and the id of the first message that reports having acted on it (done, changed, answered), or null.\n"
        f"Prompts: {json.dumps(prompts)}\n\nTranscript:\n{tx}\n\n"
        'Answer only JSON: {"<prompt id>": {"useful": "<message id or null>", "acted": "<message id or null>"}}',
        opts)
    items = ["the brief's task is done as asked"] + [f["adds"] for f in task["followups"] if f["id"] in run["sent"]]
    truth = {f["adds"]: f["truth"] for f in task["followups"] if f.get("truth")}
    checklist = judge(
        "You check an AI assistant's work against a checklist. Use the transcript and the final diff of the "
        "repo. An item is met when the diff or an answer in the transcript shows it.\n"
        f"Items: {json.dumps(items)}\nKnown right answers: {json.dumps(truth)}\n\nTranscript:\n{tx}\n\nDiff:\n{cut}\n\n"
        'Answer only JSON: {"items": [{"item": "...", "met": true|false, "why": "one line"}]}',
        opts)
    quality = judge(
        "You review a code change for a task. You see only the task, the person's follow-up instructions in "
        "order, and the final diff. Score 1 to 5: 5 = correct, complete and in scope; 3 = partly; 1 = wrong or "
        "nothing.\n"
        f"Task: {task['brief']}\nFollow-ups: {json.dumps([p[1] for p in prompts[1:]])}\n\nDiff:\n{cut}\n\n"
        'Answer only JSON: {"score": <1-5>, "why": "two lines at most"}',
        opts)

    at = {m["id"]: conv["arrivals"].get(m["id"]) for m in conv["messages"]}
    waits = {}
    for pid, _ in prompts:
        r = replies.get(pid) or {}
        sent = run["sent"][pid]
        waits[pid] = {k: (at[r[k]] - sent) / 1000 if r.get(k) in at and at[r[k]] else None for k in ("useful", "acted")}
    met = [i for i in checklist.get("items", []) if i.get("met")]
    return {
        "task": run["task"], "arm": run["arm"], "end": run.get("end"), "minutes": run.get("minutes"),
        "tokens": run.get("tokens"), "cost_usd": run_usd(run), "turns": run.get("turns"), "spawns": run.get("spawns"),
        "stall": (run.get("stall") or {}).get("summary"),
        "stall_messages": (run.get("stall") or {}).get("messages"),
        "receipts": run.get("receipts"), "flags": run.get("flags"), "leaks": len(run.get("leaks") or []),
        "first_reply_s": (run["timeline"]["brief"]["first_reply_ms"] or 0) / 1000 if run["timeline"]["brief"]["first_reply_ms"] is not None else None,
        "waits_s": waits,
        "checklist_met": f"{len(met)}/{len(checklist.get('items', []))}",
        "dropped": [i["item"] for i in checklist.get("items", []) if not i.get("met")],
        "quality": quality.get("score"), "quality_why": quality.get("why"),
        "bun_check_rc": checks.get("bun_check_rc"), "hidden_tests_rc": checks.get("hidden_tests_rc"),
        "hidden_pass": checks.get("hidden_pass"), "hidden_skip": checks.get("hidden_skip"), "hidden_fail": checks.get("hidden_fail"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outs", nargs="+")
    ap.add_argument("--tasks", default=os.path.join(HERE, "team_eval_tasks.json"))
    ap.add_argument("--judge", default=os.path.expanduser("~/.local/bin/claude"))
    ap.add_argument("--model", default="claude-opus-5-5")
    ap.add_argument("--json", default="")
    opts = ap.parse_args()
    tasks = json.load(open(opts.tasks))["tasks"]
    rows = []
    for out in opts.outs:
        row = score(out, tasks, opts)
        rows.append(row)
        print("TEAM-EVAL-SCORE " + json.dumps(row), flush=True)
    arms = by_arm(rows)
    for a in arms:
        print("TEAM-EVAL-ARM " + json.dumps(a), flush=True)
    if opts.json:
        json.dump({"runs": rows, "arms": arms}, open(opts.json, "w"), indent=1)


if __name__ == "__main__":
    main()
