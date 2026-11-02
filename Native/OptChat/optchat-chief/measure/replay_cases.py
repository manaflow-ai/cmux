#!/usr/bin/env python3
"""Model cases for evals/run.sh from a real Chief memory: replays of the person's own
messages, judged by rules only (plans/cmux-next/chief-fast-iteration.md, evals 1 to 3).

usage: replay_cases.py --db MEMORY.sqlite3 --out DIR [--dispatch IDS] [--feedback IDS]
                       [--rule KIND:RULE_ID ...] [--history 8]

Then: evals/run.sh --cases DIR (the model route as for any model case).

The cases hold the person's real words, so DIR must be outside every git work tree
(this repo is public): the script refuses one inside. The database is opened read-only.

Gold from history: a message becomes a case only when Chief started a subagent for it
(spawn) within 15 minutes, before the person's next message, and the person's next
message is not a correction ("??", "i said", "still broken", ...). The case expects what
was accepted then: a spawn, in the same repo directory.

- dispatch (eval 1, "dispatch fidelity"): a spawn, in the accepted repo directory, with a
  Title line, whose task carries at least one of the person's key words (up to 3 words
  of 5+ letters that the accepted task kept too, so a paraphrase still passes); no
  question back. A spawn with no cwd fails: the host then runs it in the Chief's own
  folder, not the repo.
- feedback (eval 2, "feedback to action"): a bug report or product note becomes a spawn
  whose task carries the person's key words; no question back.
- rule (eval 3, "rules stick"): the person taught a rule at RULE_ID; the history holds it
  and Chief's answer, and the turn is the person's next accepted dispatch after it. The
  profile has no such rule, so only the memory teaches it. KIND is the check:
  links (no raw ids), short (at most 80 words), group (the task names a Group), branch
  (the task names feat-cmux-next).
Messages with an image are left out (the runner sends no images), and so are messages
whose accepted repo is named only in older memory than the history the case holds.
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys

REPLY_WINDOW_S = 15 * 60
CORRECTION = re.compile(
    r"\?\?|\bwhy (did|didn|isn|is it|are|aren|doesn|don|can)|^no\b|not what|you didn|"
    r"didn'?t|still (not|broken|doesn|don|the same)|\bagain\b|\bwrong\b|i said|i told|"
    r"doesn'?t work|not working|\bbroken\b|where is|what happened",
    re.I,
)
SPAWN = "mcp__optchat__spawn "
REPLY_TOOLS = ("mcp__optchat__send ", "mcp__optchat__reply ")

# A profile with the eval defaults but none of the rules the rule cases teach.
NEUTRAL_PERSON = """- Act without asking for safe operations: reading, searching, read-only
  commands, edits in a worktree or scratch folder. When the person asked for
  the work, do not ask "Should I...?"; do it and report.
- Ask first only for money, legal matters, physical actions and destructive
  actions (deleting data, force pushes).
- Default project is cmux-next. The repo is manaflow-ai/cmux, checked out at ~/fun/cmux.
"""

RULE_CHECKS = {
    "links": [{"type": "no_raw_ids"}],
    "short": [{"type": "max_words", "n": 80}],
    "group": [{"type": "called", "cmd": "spawn", "re": "(?i)group:"}],
    "branch": [{"type": "called", "cmd": "spawn", "re": "feat-cmux-next"}],
}


def when(date):
    import datetime as dt
    return dt.datetime.fromisoformat(date)


def typed(m):
    return m["kind"] == "user" and not m["text"].startswith("[") and not m["text"].startswith("The server restarted")


def load(db):
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = conn.execute("SELECT id, kind, date, text FROM messages ORDER BY id").fetchall()
    conn.close()
    msgs = [{"id": i, "kind": k, "date": d, "text": t} for i, k, d, t in rows]
    return msgs, {m["id"]: n for n, m in enumerate(msgs)}


def tool_input(text, prefix):
    try:
        return json.loads(text[len(prefix):])
    except ValueError:
        return None


def has_image(msgs, n):
    m = msgs[n]
    if "image sha256:" in m["text"]:
        return True
    return n + 1 < len(msgs) and msgs[n + 1]["kind"] == "note" and msgs[n + 1]["text"].startswith("image ")


def gold(msgs, n):
    """The accepted spawn for message n: its input, or None (no spawn, or corrected)."""
    t0 = when(msgs[n]["date"])
    spawn = None
    for k in range(n + 1, len(msgs)):
        m = msgs[k]
        if typed(m):
            return spawn if spawn and not CORRECTION.search(m["text"][:220]) else None
        if (when(m["date"]) - t0).total_seconds() > REPLY_WINDOW_S:
            break
        if spawn is None and m["kind"] == "tool" and m["text"].startswith(SPAWN):
            spawn = tool_input(m["text"], SPAWN)
    return spawn


def history(msgs, n, count):
    """The `count` items before message n, as the runner seeds them. Chief's spawns and
    tells show as its own lines ("Started a12: Title"), so a message it already acted on
    does not read as unanswered."""
    items = []
    for m in reversed(msgs[:n]):
        if len(items) >= count:
            break
        text = m["text"]
        if m["kind"] == "user":
            items.append({"kind": "work" if text.startswith("[") else "user", "text": text[:1500]})
        elif m["kind"] == "talk":
            items.append({"kind": "talk", "text": text[:1500]})
        elif m["kind"] == "tool" and text.startswith(REPLY_TOOLS):
            sent = tool_input(text, text.split(" ", 1)[0] + " ")
            if sent and sent.get("text"):
                items.append({"kind": "talk", "text": sent["text"][:1500]})
        elif m["kind"] == "echo" and text.startswith("Started a"):
            started = re.findall(r"- (a\d+): (?:workspace )?\"?([^\"\n]*)", text)
            if started:
                items.append({"kind": "talk", "text": "Started " + "; ".join(
                    f"{a}: {t}" for a, t in started)[:1500]})
        elif m["kind"] == "tool" and text.startswith("mcp__optchat__tell "):
            told = tool_input(text, "mcp__optchat__tell ")
            if told and told.get("id"):
                items.append({"kind": "talk", "text": f"Told {told['id']}: {str(told.get('message', ''))[:300]}"})
    return list(reversed(items))


def first_reply(msgs, n):
    """Chief's first reply after message n (a talk message or a send/reply), or None."""
    for m in msgs[n + 1:n + 12]:
        if m["kind"] == "talk":
            return m["text"]
        if m["kind"] == "tool" and m["text"].startswith(REPLY_TOOLS):
            sent = tool_input(m["text"], m["text"].split(" ", 1)[0] + " ")
            if sent and sent.get("text"):
                return sent["text"]
        if typed(m):
            return None
    return None


STOP = set("""about above after again against also because been before being below between both
could doesn does doing down during each every from have having here into itself just make more
most need needs only other over same should some such than that their them then there these they
this those through under until very want what when where which while with would your yours""".split())


def kept_words(text, spawn, count=3):
    """Up to `count` of the person's words (5+ letters, not common) that the accepted task
    kept too, longest first: what a task for this message must carry, whatever its wording."""
    task = json.dumps(spawn).lower()
    seen, out = set(), []
    for w in sorted(re.findall(r"[A-Za-z][A-Za-z0-9]{4,}", text), key=len, reverse=True):
        lw = w.lower()
        if lw in STOP or lw in seen or lw not in task:
            continue
        seen.add(lw)
        out.append(lw)
        if len(out) == count:
            break
    return out


def cwd_re(cwd):
    """The accepted repo directory, written with ~ or the home directory."""
    if not cwd:
        return None
    tail = re.sub(r"^(~|/Users/[^/]+|/home/[^/]+)/", "", cwd.rstrip("/"))
    return r'"cwd":\s*"(~|/(Users|home)/[^/"]+)/' + re.escape(tail) + r'/?"'


def base_checks(msg, spawn):
    checks = [{"type": "called", "cmd": "spawn"}]
    words = kept_words(msg["text"], spawn)
    if words:
        # Any one of them: a task that keeps none lost what the message was about.
        checks.append({"type": "called", "cmd": "spawn",
                       "re": "(?i)" + "|".join(re.escape(w) for w in words)})
    if cwd_re(spawn.get("cwd")):
        checks.append({"type": "called", "cmd": "spawn", "re": cwd_re(spawn.get("cwd"))})
    checks.append({"type": "no_question"})
    return checks


def needs_older_memory(spawn, msg, hist):
    """The accepted repo is neither the default (~/fun/cmux) nor named in the message or
    the history: only older memory told Chief where the work lives."""
    cwd = (spawn.get("cwd") or "").rstrip("/")
    name = os.path.basename(cwd)
    if not name or re.search(r"(^|/)fun/cmux$", cwd):
        return False
    seen = (msg["text"] + " " + " ".join(h["text"] for h in hist)).lower()
    return name.lower() not in seen


def case(cid, group, about, hist, msg, checks, person=None):
    out = {"id": cid, "group": group, "owner": "replay", "about": about, "history": hist,
           "turns": [{"text": msg["text"], "checks": checks}]}
    if person:
        out["person"] = person
    return out


def build(msgs, idx, args):
    cases, skipped = [], []
    for kind, ids in (("dispatch", args.dispatch), ("feedback", args.feedback)):
        for mid in ids:
            n = idx.get(mid)
            if n is None or not typed(msgs[n]):
                skipped.append((mid, "not a typed message"))
                continue
            if has_image(msgs, n):
                skipped.append((mid, "has an image"))
                continue
            spawn = gold(msgs, n)
            if spawn is None:
                skipped.append((mid, "no accepted spawn"))
                continue
            hist = history(msgs, n, args.history)
            if needs_older_memory(spawn, msgs[n], hist):
                skipped.append((mid, "its repo is named only in older memory"))
                continue
            checks = base_checks(msgs[n], spawn)
            if kind == "dispatch":
                checks.insert(1, {"type": "called", "cmd": "spawn", "re": "Title:"})
                about = "a real dispatch is spawned in the accepted repo with the person's words and a title"
            else:
                about = "a real bug report or product note becomes a subagent with the person's words"
            cases.append(case(f"{kind}-m{mid}", kind, about, hist, msgs[n], checks))
    for spec in args.rule:
        kind, _, rid = spec.partition(":")
        rid = int(rid)
        if kind not in RULE_CHECKS or rid not in idx:
            skipped.append((spec, "unknown rule kind or id"))
            continue
        r = idx[rid]
        later = next((k for k in range(r + 20, len(msgs))
                      if typed(msgs[k]) and not has_image(msgs, k) and len(msgs[k]["text"]) > 30
                      and gold(msgs, k) is not None), None)
        if later is None:
            skipped.append((spec, "no accepted dispatch after the rule"))
            continue
        # The rule as the person wrote it, then Chief's first answer to it.
        hist = [{"kind": "user", "text": msgs[r]["text"][:1500]}]
        answer = first_reply(msgs, r)
        if answer:
            hist.append({"kind": "talk", "text": answer[:1500]})
        checks = [{"type": "called", "cmd": "spawn"}] + RULE_CHECKS[kind]
        cases.append(case(f"rules-{kind}-m{rid}-m{msgs[later]['id']}", "rules",
                          f"a {kind} rule the person taught earlier holds on a later dispatch",
                          hist, msgs[later], checks, person=NEUTRAL_PERSON))
    return cases, skipped


def inside_git(path):
    probe = path
    while not os.path.isdir(probe):
        probe = os.path.dirname(probe) or "."
    r = subprocess.run(["git", "-C", probe, "rev-parse", "--is-inside-work-tree"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "true"


def ids(text):
    return [int(x) for x in text.split(",") if x.strip()] if text else []


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--dispatch", type=ids, default=[])
    ap.add_argument("--feedback", type=ids, default=[])
    ap.add_argument("--rule", action="append", default=[])
    ap.add_argument("--history", type=int, default=8)
    a = ap.parse_args(argv)
    out = os.path.abspath(a.out)
    if inside_git(out):
        print(f"refused: {out} is inside a git work tree; the cases hold the person's real words", file=sys.stderr)
        return 2
    msgs, idx = load(a.db)
    cases, skipped = build(msgs, idx, a)
    os.makedirs(out, mode=0o700, exist_ok=True)
    for c in cases:
        path = os.path.join(out, c["id"] + ".json")
        with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump(c, f, indent=1, ensure_ascii=False)
    print(f"wrote {len(cases)} cases to {out}")
    for what, why in skipped:
        print(f"skipped {what}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
