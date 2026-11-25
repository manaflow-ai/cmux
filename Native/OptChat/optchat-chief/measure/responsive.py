#!/usr/bin/env python3
"""Responsiveness the person feels, measured on a scratch Chief (chief_driver.py
--scenario responsive) and reported over one or more runs.

Clock: every time is the wall clock of this script. A message's clock starts
just before its `conversation-op` (the composer's send) is written, and every
sign the person can see is stamped when its event arrives on a `subscribe`
connection to the same daemon the app reads: typing dots, the Chief's read
cursor, a tapback, a reply draft, a run step or live frame, and each posted
message. Nothing is estimated from the host's own trace; the trace only adds
why (turns, requests, cache, steers). The read cursor counts only as a
message's ack (the composer shows it per message), not as a sign of work.

Per probe (one or more person messages, sent at fixed offsets):
  sign_ms     first visible sign of work after the first message
              (typing, a tapback, a draft or thought, a run step, a live frame,
              a message)
  useful_ms   first Chief text with a real sentence (not an ack-only line)
  final_ms    the last Chief message of the probe (for a delegated task: the
              first message after the subagent's report)
  per message:
    ack_ms      first sign for THIS message: a tapback on it, a reply to it,
                its read by the Chief, or a Chief message after it
    acted_ms    first Chief message that carries this message's expected answer
    stale       a Chief message posted after a correction that still carries
                the corrected (wrong) value and not the right one

CLI:
  responsive.py report RUN_DIR... [--json OUT] [--label NAME]
      aggregates runs (each RUN_DIR has responsive.json), prints a markdown
      table of median and p90 per class and metric, and one RESPONSIVENESS
      line of JSON.
"""
import json
import os
import re
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scenario  # noqa: E402

AGENT = "agent_mux"
ACK_ONLY = re.compile(
    r"^\s*(on it|looking|checking|got it|noted|ok(ay)?|sure|one (sec|moment)|working on it|let me (check|look))\b[^.!?\n\d]{0,40}[.!…]?\s*$",
    re.I,
)


def _facts():
    log = scenario.FIXTURES["fixtures/app.log"].splitlines()
    err = {}
    warn = 0
    services = []
    for line in log:
        parts = line.split()
        if len(parts) < 3:
            continue
        level, svc = parts[1], parts[2]
        if svc not in services:
            services.append(svc)
        if level == "ERROR":
            err[svc] = err.get(svc, 0) + 1
        if level == "WARN":
            warn += 1
    return {
        "lines": len(log),
        "errors": sum(err.values()),
        "warn": warn,
        "services": services,
        "b_py_lines": len(scenario.FIXTURES["fixtures/sub/b.py"].splitlines()),
    }


FACTS = _facts()


def probes(idle_s=0):
    """The scripted asks, in order. Offsets are seconds after the probe's first send."""
    f = FACTS
    out = [
        # The first message after the brain started (no turn has run yet).
        {"id": "cold", "class": "cold_start", "msgs": [(0, "Hi Chief. What is 12 plus 30? Just the number.", r"\b42\b")]},
        {"id": "trivial", "class": "trivial", "msgs": [(0, "What is 17 times 23? Just the number.", r"\b391\b")]},
        {"id": "lookup", "class": "lookup", "msgs": [
            (0, "How many ERROR lines are in {work}/fixtures/app.log? Just the number.", rf"\b{f['errors']}\b")]},
        {"id": "small", "class": "small_task", "msgs": [
            (0, "In {work}/fixtures/config.toml set idle_timeout_s to 120, then tell me the old value.", r"\b90\b")]},
        {"id": "delegated", "class": "delegated", "delegated": True, "msgs": [
            (0, "Hand this to a subagent: count the TODO items in {work}/fixtures/sub2/x.md and {work}/fixtures/sub2/y.md and report each count.",
             r"\b3\b[\s\S]*\b6\b|\b6\b[\s\S]*\b3\b")]},
        # A correction 4 s later.
        {"id": "burst2", "class": "burst2", "msgs": [
            (0, "What is 19 times 21? Just the number.", None),
            (4, "Sorry, I meant 19 times 22.", r"\b418\b")], "stale": (1, r"\b399\b", r"\b418\b")},
        # Additions to one ask.
        {"id": "burst3", "class": "burst3", "msgs": [
            (0, "Which services write to {work}/fixtures/app.log?", "|".join(re.escape(s) for s in f["services"][:2])),
            (3, "Also: how many WARN lines does it have?", rf"\b{f['warn']}\b"),
            (6, "And how many lines does the file have in total?", rf"\b{f['lines']}\b")]},
        # Unrelated asks, a delegation and a correction within 10 s.
        {"id": "burst5", "class": "burst5", "msgs": [
            (0, "What port does {work}/fixtures/config.toml set?", r"\b8443\b"),
            (2, "Unrelated: what is 7 times 8? Just the number.", None),
            (4, "Also, what is the cache ttl_s in that same config file?", r"\b600\b"),
            (6, "Start a subagent that counts the lines of {work}/fixtures/sub/b.py and reports the number.", rf"\b{f['b_py_lines']}\b"),
            (8, "Correction: I meant 7 times 9, not 7 times 8.", r"\b63\b")], "stale": (4, r"\b56\b", r"\b63\b")},
        # A message while a long tool call runs in the Chief's own turn.
        {"id": "steer", "class": "steer", "msgs": [
            (0, "Run this in a shell yourself, no subagent, and tell me what it prints: sleep 40; echo done-$((6*7))", r"done-42"),
            (8, "While that runs: what is 5 plus 6? Just the number.", r"\b11\b")]},
    ]
    if idle_s:
        out.append({"id": "idle", "class": "cold_idle", "gap": idle_s,
                    "msgs": [(0, "What is 9 times 9? Just the number.", r"\b81\b")]})
    return out


class Recorder:
    """A subscribe connection to the daemon; stamps each conversation event."""

    def __init__(self, sock_path, conversation):
        self.conv = conversation
        self.events = []
        self.lock = threading.Lock()
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(sock_path)
        self._send({"id": 1, "cmd": "set-client-info", "name": "responsiveness-bench", "kind": "bench",
                    "capabilities": ["conversation-draft-events-v1", "conversation-runs-v1", "chief-live-v1"]})
        self._send({"id": 2, "cmd": "subscribe"})
        self.t = threading.Thread(target=self._read, daemon=True)
        self.t.start()

    def _send(self, obj):
        self.s.sendall((json.dumps(obj) + "\n").encode())

    def _read(self):
        buf = b""
        while True:
            try:
                chunk = self.s.recv(1 << 20)
            except OSError:
                return
            if not chunk:
                return
            t = int(time.time() * 1000)
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                name = e.get("event")
                if not name or not str(name).startswith("conversation"):
                    continue
                if e.get("conversation") not in (None, self.conv):
                    continue
                with self.lock:
                    self.events.append({"t": t, "e": e})

    def snapshot(self):
        with self.lock:
            return list(self.events)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def _text(msg):
    return "\n".join(p.get("text", "") for p in msg.get("parts", []) if p.get("type") == "text")


def _reply_to(msg):
    r = msg.get("reply_to")
    if isinstance(r, dict):
        return r.get("message_id") or r.get("id")
    return r


def _ms(stamp):
    """RFC 3339 to epoch ms (0 when unreadable)."""
    from datetime import datetime
    try:
        return int(datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return 0


def signs(events, t0, t1, agent=AGENT):
    """Visible Chief signs between t0 and t1 (ms), each (t, kind, detail)."""
    out = []
    for rec in events:
        t, e = rec["t"], rec["e"]
        if t < t0 or (t1 is not None and t > t1):
            continue
        ev = e.get("event")
        if ev == "conversation-typing" and e.get("participant") == agent and e.get("on"):
            out.append((t, "typing", None))
        elif ev == "conversation-draft":
            item = e.get("item") or {}
            if (item.get("participant") or e.get("participant")) == agent and (item.get("text") or "").strip():
                out.append((t, "thought" if item.get("kind") == "thought" else "draft", item.get("text")))
        elif ev in ("conversation-run-changed", "conversation-live"):
            out.append((t, "run", None))
        elif ev == "conversation-changed":
            ch = e.get("change") or {}
            kind = ch.get("kind")
            msg = ch.get("message") or {}
            if kind == "message" and msg.get("author") == agent:
                out.append((t, "message", msg))
            elif kind == "message-updated":
                # The event carries every reaction on the message: count only a
                # Chief tapback made in this window (`at` is RFC 3339).
                for r in msg.get("reactions") or []:
                    if r.get("author") == agent and _ms(r.get("at")) >= t0:
                        out.append((t, "reaction", msg))
            elif kind == "read-cursor" and ch.get("participant") == agent:
                out.append((t, "read", ch.get("seq")))
    out.sort(key=lambda x: x[0])
    return out


def measure_probe(probe, sent, events, t_end, trace):
    """One probe's numbers from the recorded events. `sent`: [(t_ms, msg_id, seq)]."""
    t0 = sent[0][0]
    sg = signs(events, t0, t_end)
    agent_msgs = [(t, d) for (t, k, d) in sg if k == "message"]
    first_sign = next((t for (t, k, d) in sg if k in ("typing", "draft", "thought", "run", "message", "reaction")), None)
    # Useful: Chief words with a whole sentence or an expected answer, never an
    # ack-only line ("On it.") and never a fragment of a streaming draft.
    wants = [m[2] for m in probe["msgs"] if m[2]]
    useful = None
    for (t, k, d) in sg:
        txt = d if k == "draft" else (_text(d) if k == "message" else None)
        if not txt or ACK_ONLY.match(txt):
            continue
        whole = k == "message" or re.search(r"[.!?:](\s|$)", txt.strip())
        if any(re.search(w, txt, re.I) for w in wants) or (whole and len(txt.strip()) >= 12):
            useful = t
            break
    final = agent_msgs[-1][0] if agent_msgs else None
    if probe.get("delegated"):
        reports = [e["ts"] for e in trace if e.get("ev") == "spawn.report" and t0 <= e.get("ts", 0) <= t_end]
        if reports:
            after = [t for (t, _) in agent_msgs if t >= reports[-1]]
            final = after[0] if after else None
    per = []
    for i, (t, mid, seq) in enumerate(sent):
        want = probe["msgs"][i][2]
        mine = signs(events, t, t_end)
        # Ack: a sign that names THIS message (a tapback on it, a reply to it,
        # an answer that lists it) or the Chief's read cursor passing it.
        ack = None
        for (ts, k, d) in mine:
            if k == "reaction" and d.get("id") == mid:
                ack = ts
            elif k == "message" and (_reply_to(d) == mid or mid in (d.get("answers") or [])):
                ack = ts
            elif k == "read" and seq is not None and d is not None and d >= seq:
                ack = ts
            if ack:
                break
        nxt = next((ts for (ts, k, d) in mine if k == "message"), None)
        acted = None
        if want:
            for (ts, d) in agent_msgs:
                if ts >= t and re.search(want, _text(d), re.I):
                    acted = ts
                    break
        per.append({"i": i, "sent": t, "ack_ms": ack - t if ack else None,
                    "next_msg_ms": nxt - t if nxt else None,
                    "acted_ms": acted - t if acted else None, "expected": bool(want),
                    "ok": (acted is not None) if want else None})
    stale = None
    if probe.get("stale"):
        idx, bad, good = probe["stale"]
        tc = sent[idx][0]
        stale = any(ts > tc + 1500 and re.search(bad, _text(d)) and not re.search(good, _text(d)) for (ts, d) in agent_msgs)
    # Cross-blocking: a later message's answer waited for an earlier, unrelated one.
    turns = [e for e in trace if e.get("ev") in ("turn.start", "turn.end", "turn.interrupt") and t0 <= e.get("ts", 0) <= t_end]
    ends = [e for e in turns if e.get("ev") == "turn.end"]
    starts = [e for e in turns if e.get("ev") == "turn.start"]
    req = [e for e in trace if e.get("ev") == "request" and t0 <= e.get("ts", 0) <= t_end]
    use = {k: sum((e.get("usage") or {}).get(k) or 0 for e in req) for k in ("input", "cache_read", "cache_write", "output")}
    first_req = [s.get("first_usage") for s in ends if s.get("first_usage")]
    return {
        "id": probe["id"], "class": probe["class"], "t0": t0,
        "sign_ms": first_sign - t0 if first_sign else None,
        "sign_kind": next((k for (t, k, d) in sg if t == first_sign), None),
        "useful_ms": useful - t0 if useful else None,
        "final_ms": final - t0 if final else None,
        "msgs": per, "stale": stale,
        "turns": len(starts), "superseded": sum(1 for e in ends if e.get("status") == "superseded"),
        "interrupts": sum(1 for e in turns if e.get("ev") == "turn.interrupt"),
        "requests": len(req), "usage": use,
        "first_ttft_ms": [e.get("ttft_ms") for e in ends],
        "first_cache_read": [u.get("cache_read") for u in first_req],
        "first_cache_write": [u.get("cache_write") for u in first_req],
        "cost_usd": round(sum(e.get("cost_usd") or 0 for e in ends), 4),
        "agent_texts": [_text(d)[:300] for (_, d) in agent_msgs],
    }


def run(ctx):
    """Drive every probe on the scratch brain. ctx: the driver's helpers."""
    log, send, conv, sock, work, out = ctx["log"], ctx["send"], ctx["conv"], ctx["sock"], ctx["work"], ctx["out"]
    trace_events, idle, last_seq = ctx["trace_events"], ctx["idle"], ctx["last_seq"]
    only = set(filter(None, (ctx.get("only") or "").split(",")))
    rec = Recorder(sock, conv)
    results = []
    try:
        for probe in probes(ctx.get("idle_s") or 0):
            if only and probe["id"] not in only and probe["id"] != "cold":
                continue
            if probe.get("gap"):
                log(f"idle {probe['gap']} s before {probe['id']}")
                time.sleep(probe["gap"])
            sent = []
            start = time.time()
            for (off, text, _) in probe["msgs"]:
                wait = start + off - time.time()
                if wait > 0:
                    time.sleep(wait)
                t = int(time.time() * 1000)
                key = f"{probe['id']}-{len(sent)}-{t}"
                seq = send(text.replace("{work}", work), key)
                mid = None
                for r in rec.snapshot()[::-1]:
                    m = ((r["e"].get("change") or {}).get("message") or {})
                    if m.get("client_msg_id") == key:
                        mid = m.get("id")
                        break
                sent.append([t, mid, seq])
                log(f"sent {probe['id']}#{len(sent) - 1}")
            deadline = time.time() + ctx.get("timeout", 600)
            t_first = sent[0][0]
            went_idle = False
            while time.time() < deadline:
                if idle(t_first):
                    went_idle = True
                    break
                time.sleep(0.5)
            t_end = int(time.time() * 1000)
            # Message ids for sends whose echo arrived after the lookup above.
            for s in sent:
                if s[1] is None:
                    for r in rec.snapshot():
                        m = ((r["e"].get("change") or {}).get("message") or {})
                        if m.get("author") != AGENT and m.get("seq") == s[2]:
                            s[1] = m.get("id")
            res = measure_probe(probe, [tuple(s) for s in sent], rec.snapshot(), t_end, trace_events())
            res["timeout"] = not went_idle
            results.append(res)
            log(f"probe {probe['id']}: sign {res['sign_ms']} ms, useful {res['useful_ms']} ms, final {res['final_ms']} ms, "
                f"turns {res['turns']}, msgs {[(m['ack_ms'], m['acted_ms']) for m in res['msgs']]}")
            # What the Chief said, and when, so a step log alone explains a miss.
            said = []
            for r in rec.snapshot():
                ch = r["e"].get("change") or {}
                m = ch.get("message") or {}
                if (t_first <= r["t"] <= t_end and ch.get("kind") == "message"
                        and m.get("author") == AGENT and _text(m).strip()):
                    said.append((r["t"] - t_first, _text(m)[:160]))
            log(f"probe-texts {probe['id']}: {json.dumps(said)}")
            tr = [e for e in trace_events() if t_first <= e.get("ts", 0) <= t_end
                  and e.get("ev") in ("turn.start", "turn.end", "turn.interrupt", "tool", "spawn", "spawn.report")]
            log(f"probe-trace {probe['id']}: " + json.dumps([
                [e["ts"] - t_first, e["ev"], e.get("name") or e.get("status") or e.get("why") or "",
                 e.get("ms")] + ([{"ttft": e.get("ttft_ms"), "start": e.get("start_ms"),
                                   "cost": e.get("cost_usd"), "req": e.get("requests"),
                                   "first": e.get("first_usage")}] if e.get("ev") == "turn.end" else [])
                for e in tr]))
            time.sleep(3)
    finally:
        json.dump({"results": results, "events": rec.snapshot()}, open(os.path.join(out, "responsive.json"), "w"))
        rec.close()
    return results


# ---------------------------------------------------------------- report

def _q(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo))


def aggregate(dirs):
    rows = []
    for d in dirs:
        p = os.path.join(d, "responsive.json") if os.path.isdir(d) else d
        try:
            rows += json.load(open(p))["results"]
        except (OSError, ValueError, KeyError):
            continue
    classes = []
    for r in rows:
        if r["class"] not in classes:
            classes.append(r["class"])
    table = {}
    for c in classes:
        rs = [r for r in rows if r["class"] == c]
        acks = [m["ack_ms"] for r in rs for m in r["msgs"]]
        nexts = [m.get("next_msg_ms") for r in rs for m in r["msgs"]]
        acted = [m["acted_ms"] for r in rs for m in r["msgs"] if m["expected"]]
        later_acted = [m["acted_ms"] for r in rs for m in r["msgs"] if m["expected"] and m["i"] > 0]
        oks = [m["ok"] for r in rs for m in r["msgs"] if m["expected"]]
        cw = [x for r in rs for x in r.get("first_cache_write") or [] if x is not None]
        cr = [x for r in rs for x in r.get("first_cache_read") or [] if x is not None]
        table[c] = {
            "runs": len(rs),
            "sign": (_q([r["sign_ms"] for r in rs], .5), _q([r["sign_ms"] for r in rs], .9)),
            "useful": (_q([r["useful_ms"] for r in rs], .5), _q([r["useful_ms"] for r in rs], .9)),
            "final": (_q([r["final_ms"] for r in rs], .5), _q([r["final_ms"] for r in rs], .9)),
            "ack_each": (_q(acks, .5), _q(acks, .9)),
            "next_msg_each": (_q(nexts, .5), _q(nexts, .9)),
            "acted_each": (_q(acted, .5), _q(acted, .9)),
            "acted_later": (_q(later_acted, .5), _q(later_acted, .9)),
            "correct": f"{sum(1 for o in oks if o)}/{len(oks)}",
            "stale": sum(1 for r in rs if r.get("stale")),
            "timeouts": sum(1 for r in rs if r.get("timeout")),
            "turns": _q([r["turns"] for r in rs], .5),
            "superseded": sum(r["superseded"] for r in rs),
            "first_cache_read_pct": round(100 * sum(cr) / max(1, sum(cr) + sum(cw)), 1) if cr or cw else None,
            "cost_usd": round(sum(r.get("cost_usd") or 0 for r in rs) / max(1, len(rs)), 3),
        }
    return table, rows


def _s(v):
    if v is None:
        return "-"
    return f"{v / 1000:.1f}"


def markdown(table, label):
    head = ("| class | n | sign p50/p90 s | useful p50/p90 s | final p50/p90 s | ack each p50/p90 s | "
            "acted each p50/p90 s | later msgs acted p50/p90 s | correct | stale | turns | 1st-req cache read % | $/probe |")
    out = [f"### {label}", "", head, "|" + "---|" * 13]
    for c, t in table.items():
        out.append(f"| {c} | {t['runs']} | {_s(t['sign'][0])} / {_s(t['sign'][1])} | {_s(t['useful'][0])} / {_s(t['useful'][1])} | "
                   f"{_s(t['final'][0])} / {_s(t['final'][1])} | {_s(t['ack_each'][0])} / {_s(t['ack_each'][1])} | "
                   f"{_s(t['acted_each'][0])} / {_s(t['acted_each'][1])} | {_s(t['acted_later'][0])} / {_s(t['acted_later'][1])} | "
                   f"{t['correct']} | {t['stale']} | {t['turns']} | {t['first_cache_read_pct']} | {t['cost_usd']} |")
    return "\n".join(out)


def main(argv):
    if len(argv) < 2 or argv[0] != "report":
        print(__doc__)
        return 2
    label, jout, dirs = "run", None, []
    it = iter(argv[1:])
    for a in it:
        if a == "--label":
            label = next(it)
        elif a == "--json":
            jout = next(it)
        else:
            dirs.append(a)
    table, rows = aggregate(dirs)
    print(markdown(table, label))
    print("RESPONSIVENESS " + json.dumps({"label": label, "table": table}))
    if jout:
        json.dump({"label": label, "table": table, "rows": rows}, open(jout, "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
