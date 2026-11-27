#!/usr/bin/env python3
"""The failure cases of a real Chief, to read: one HTML page, no model, read-only.

usage: chief_digest.py [--home OPTCHAT_DIR | --db MEMORY.sqlite3] [--since 1d]
                       [--out FILE.html] [--title NAME]

Each case shows the person's words, what Chief did next (its first tool calls
and reply) and what came after, so a person can label it. The page holds the
person's real messages: write it outside every git work tree (the default is
~/.cache/chief-evals/digests/). Kinds:

- corrected: the person's next message corrects Chief ("??", "i said", "still broken").
- no reply: no reply within 15 minutes (acknowledgements left out).
- turn failed: a "the turn failed (...)" note the person saw.
- cut by restart: the "The server restarted, cutting the turn" notice.
- message not delivered: host.log says a message could not reach the running turn.
- tool error: a cmux usage error, a "No such tool", or a failed send/reply/react.
- no workspace: a subagent started without a workspace.

Each kind is tagged plumbing (the host or the machine failed) or behavior (the
model chose wrong), so plumbing gets a code fix and behavior a prompt or model fix.
"""
import argparse
import datetime as dt
import html
import os
import re
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import chief_health as h  # noqa: E402

CORRECTION = re.compile(
    r"\?\?|\bwhy (did|didn|isn|is it|are|aren|doesn|don|can)|^no\b|not what|you didn|"
    r"didn'?t|still (not|broken|doesn|don|the same)|\bwrong\b|i said|i told|"
    r"doesn'?t work|not working|\bbroken\b|where is|what happened",
    re.I,
)
KINDS = {
    "corrected": ("behavior", "The person's next message corrects Chief"),
    "no reply": ("behavior", "No reply within 15 minutes"),
    "turn failed": ("plumbing", "A turn failure the person saw"),
    "cut by restart": ("plumbing", "A turn cut by a server restart"),
    "message not delivered": ("plumbing", "A message could not reach the running turn"),
    "tool error": ("behavior", "A tool call Chief made wrong"),
    "no workspace": ("plumbing", "A subagent started without a workspace"),
}


def load(db):
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = conn.execute("SELECT id, kind, date, text FROM messages ORDER BY id").fetchall()
    conn.close()
    return [{"id": i, "kind": k, "date": d, "text": t} for i, k, d, t in rows]


def after(msgs, n, count=6):
    """What came after message n: up to `count` items, until the person's next message."""
    out = []
    for m in msgs[n + 1:n + 1 + 40]:
        out.append(m)
        if len(out) >= count or (h.typed(m) and out[:-1]):
            break
    return out


def steer_failures(host_log, tz):
    times = []
    try:
        lines = open(host_log, errors="replace")
    except OSError:
        return times
    for line in lines:
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) optchat-chief: turn \S+: "
                     r"(the message could not reach the running turn|a new message cannot reach it)", line)
        if m:
            times.append(dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=tz))
    return times


def cases(msgs, start, host_log):
    out = []
    typed_idx = [n for n, m in enumerate(msgs) if h.typed(m)]
    replies = {m["id"]: secs for m, secs, _ in h.replies(msgs, start)}
    tz = h.when(msgs[-1]["date"]).tzinfo if msgs else None
    steers = steer_failures(host_log, tz)
    for k, n in enumerate(typed_idx):
        m = msgs[n]
        if h.when(m["date"]) < start or h.ACK.match(m["text"]):
            continue
        nxt = msgs[typed_idx[k + 1]] if k + 1 < len(typed_idx) else None
        if nxt and CORRECTION.search(nxt["text"][:220]) and \
                (h.when(nxt["date"]) - h.when(m["date"])).total_seconds() < 3600:
            out.append(("corrected", n, nxt))
        if m["id"] in replies and replies[m["id"]] is None:
            out.append(("no reply", n, None))
        t0 = h.when(m["date"])
        if any(0 <= (s - t0).total_seconds() <= 120 for s in steers):
            out.append(("message not delivered", n, None))
    for n, m in enumerate(msgs):
        if h.when(m["date"]) < start:
            continue
        if m["kind"] == "note" and m["text"].startswith(h.FAILED_NOTE):
            out.append(("turn failed", n, None))
        elif m["kind"] == "user" and m["text"].startswith(h.RESTART_NOTICE):
            out.append(("cut by restart", n, None))
        elif m["kind"] == "tool" and n + 1 < len(msgs) and msgs[n + 1]["kind"] == "echo":
            echo = msgs[n + 1]["text"].lstrip()
            if echo.startswith("cmux: usage") or "No such tool" in echo[:200] or (
                    m["text"].startswith(("mcp__optchat__send ", "mcp__optchat__reply ", "mcp__optchat__react "))
                    and echo.startswith("error:")):
                out.append(("tool error", n, None))
            elif m["text"].startswith("mcp__optchat__spawn") and "no cmux workspace" in echo:
                out.append(("no workspace", n + 1, None))
    return out


def person_before(msgs, n):
    for m in reversed(msgs[:n + 1]):
        if h.typed(m):
            return m
    return None


def short(text, limit=600):
    text = text.strip()
    return text if len(text) <= limit else text[:limit] + " …"


def item_html(msg, label=None):
    who = {"user": "person" if h.typed(msg) else "report/notice", "talk": "Chief", "tool": "Chief tool",
           "echo": "tool result", "note": "note"}.get(msg["kind"], msg["kind"])
    tag = f'<span class="who">{html.escape(label or who)}</span>'
    return (f'<div class="msg {msg["kind"]}">{tag}<span class="meta">line {msg["id"]} · '
            f'{html.escape(msg["date"][:16].replace("T", " "))}</span><pre>{html.escape(short(msg["text"]))}</pre></div>')


def render(title, found, msgs, since_text):
    counts = {}
    for kind, _, _ in found:
        counts[kind] = counts.get(kind, 0) + 1
    parts = [f"""<!doctype html><meta charset="utf-8"><title>{html.escape(title)}</title>
<style>
body{{font:14px -apple-system,system-ui,sans-serif;margin:24px;max-width:1100px;color:#222;background:#fff}}
@media(prefers-color-scheme:dark){{body{{color:#ddd;background:#1e1e1e}} .msg{{background:#2a2a2a!important}} .person{{background:#203040!important}}}}
h1{{font-size:20px}} h2{{font-size:16px;margin-top:28px}} table{{border-collapse:collapse}} td,th{{padding:3px 10px;text-align:left}}
.case{{border-left:3px solid #c55;padding:6px 12px;margin:14px 0}} .case.plumbing{{border-color:#c90}}
.msg{{background:#f4f4f4;border-radius:6px;padding:6px 8px;margin:4px 0}} .person{{background:#e6f0fb}}
.who{{font-weight:600;margin-right:8px}} .meta{{color:#888;font-size:12px}} pre{{white-space:pre-wrap;margin:4px 0 0;font:13px ui-monospace,monospace}}
.tag{{font-size:12px;padding:1px 6px;border-radius:4px;background:#eee;color:#333;margin-left:6px}}
</style>
<h1>{html.escape(title)}</h1>
<p>Window: {html.escape(since_text)}. {len(found)} cases. Plumbing = a host or machine fault (code fix);
behavior = the model chose wrong (prompt or model fix).</p><table><tr><th>Kind</th><th>Type</th><th>Cases</th></tr>"""]
    for kind, (typ, about) in KINDS.items():
        parts.append(f'<tr><td><a href="#{kind.replace(" ", "-")}">{kind}</a></td><td>{typ}</td>'
                     f'<td>{counts.get(kind, 0)}</td></tr>')
    parts.append("</table>")
    for kind, (typ, about) in KINDS.items():
        mine = [f for f in found if f[0] == kind]
        if not mine:
            continue
        parts.append(f'<h2 id="{kind.replace(" ", "-")}">{html.escape(kind)} ({len(mine)}) '
                     f'<span class="tag">{typ}</span></h2><p>{html.escape(about)}.</p>')
        for _, n, extra in sorted(mine, key=lambda f: -msgs[f[1]]["id"]):
            m = msgs[n]
            parts.append(f'<div class="case {typ}">')
            ask = person_before(msgs, n) if not h.typed(m) else m
            if ask is not None and ask is not m:
                parts.append(item_html(ask, "person (before)").replace('class="msg user"', 'class="msg user person"'))
            parts.append(item_html(m).replace('class="msg user"', 'class="msg user person"'))
            for nxt in after(msgs, n):
                if extra is not None and nxt["id"] == extra["id"]:
                    break
                parts.append(item_html(nxt))
            if extra is not None:
                parts.append(item_html(extra, "person (correction)").replace('class="msg user"', 'class="msg user person"'))
            parts.append("</div>")
    return "\n".join(parts)


def inside_git(path):
    import subprocess
    probe = os.path.dirname(os.path.abspath(path))
    while not os.path.isdir(probe):
        probe = os.path.dirname(probe)
    r = subprocess.run(["git", "-C", probe, "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "true"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--home", default=os.path.expanduser("~/.cmux/chief/default/optchat"))
    ap.add_argument("--db")
    ap.add_argument("--host-log")
    ap.add_argument("--since", default="1d")
    ap.add_argument("--now")
    ap.add_argument("--title", default="Chief failure cases")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    db = a.db or os.path.join(a.home, "memory.sqlite3")
    host_log = a.host_log or os.path.join(os.path.dirname(a.home.rstrip("/")), "host.log")
    now = dt.datetime.fromisoformat(a.now) if a.now else dt.datetime.now(dt.timezone.utc).astimezone()
    start = now - h.parse_since(a.since)
    out = a.out or os.path.expanduser(f"~/.cache/chief-evals/digests/{now.date().isoformat()}.html")
    if inside_git(out):
        print(f"refused: {out} is inside a git work tree; the page holds the person's real words", file=sys.stderr)
        return 2
    msgs = load(db)
    found = cases(msgs, start, host_log)
    page = render(a.title, found, msgs, f"since {start.isoformat(timespec='minutes')}")
    os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
    with open(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(page)
    counts = {}
    for kind, _, _ in found:
        counts[kind] = counts.get(kind, 0) + 1
    print(out)
    print("; ".join(f"{k}={v}" for k, v in counts.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
