#!/usr/bin/env python3
"""The scripted conversations of the Chief parity harness, shared by both sides.
(This file is the only copy: other parity harnesses load it from here.)

Two scenarios:
  smoke  ~18 turns: short questions, a long paste, tool turns in a scratch
         work dir, recall of earlier turns, three subagent turns (one with a
         follow-up sent while the subagents run), gaps of 0 s, 30 s and 6 min.
  soak   a ~2,000-message imported history (a fixed synthetic Claude Code
         corpus with planted facts), then 110 turns with mixed gaps (0 s,
         30 s, 6 min, two over 1 h), recall at several ages, tool, paste and
         subagent turns.

Everything is deterministic (fixed seeds), so both sides and every build get
the same bytes. `{work}` in a turn's text is the side's scratch work dir.

CLI (used by the drivers; prints JSON):
  scenario.py turns smoke|soak            the turn list
  scenario.py fixtures DIR                write the work-dir fixtures into DIR
  scenario.py corpus DIR                  write the soak corpus as Claude Code
                                          projects JSONL under DIR/projects
  scenario.py check TURN_ID REPLY_FILE    correctness of one reply (JSON)
"""
import hashlib
import json
import os
import random
import re
import sys

# ---------------------------------------------------------------- fixtures

def _fixture_files():
    rnd = random.Random(11)
    files = {}
    lines = []
    services = ["api-gateway", "ledger-sync", "auth", "billing", "search-index"]
    error_at = set(rnd.sample(range(200), 17))
    for i in range(200):
        svc = services[i % len(services)]
        level = "ERROR" if i in error_at else rnd.choice(["INFO", "INFO", "DEBUG", "WARN"])
        lines.append(f"2026-10-01T12:{i // 60:02d}:{i % 60:02d}Z {level} {svc} request {1000 + i} took {rnd.randint(3, 900)}ms")
    files["fixtures/app.log"] = "\n".join(lines) + "\n"
    files["fixtures/config.toml"] = (
        "[server]\nhost = \"0.0.0.0\"\nport = 8443\nmax_connections = 384\n"
        "idle_timeout_s = 90\n\n[cache]\nbackend = \"redis\"\nttl_s = 600\n"
    )
    defs = {"a.py": ["load", "parse_header", "validate", "emit"],
            "b.py": ["start", "stop", "reconnect_with_backoff", "drain", "flush", "close", "health"],
            "c.py": ["read", "write", "merge_overlapping_ranges", "sort_keys", "dump"]}
    for name, fns in defs.items():
        body = [f'"""Module {name}: part of the parity fixture."""', "import os", ""]
        for fn in fns:
            body += [f"def {fn}(value=None):", f"    # {fn} handles one step", "    return value", ""]
        body += ["CONSTANT = 3", "# def not_a_function_comment"]
        files[f"fixtures/sub/{name}"] = "\n".join(body) + "\n"
    for name, n in (("x.md", 3), ("y.md", 6)):
        out = [f"# Notes {name}", ""]
        for k in range(12):
            out.append(f"- TODO item {k} in {name}" if k < n else f"- done item {k} in {name}")
        files[f"fixtures/sub2/{name}"] = "\n".join(out) + "\n"
    totals = {}
    for q in ("q1", "q2", "q3"):
        rows = ["id,customer,amount"]
        total = 0
        for k in range(10):
            amt = rnd.randint(10, 500)
            total += amt
            rows.append(f"{k},cust-{rnd.randint(100, 999)},{amt}")
        totals[q] = total
        files[f"fixtures/sub3/{q}.csv"] = "\n".join(rows) + "\n"
    return files, totals


FIXTURES, CSV_TOTALS = _fixture_files()
CSV_GRAND = sum(CSV_TOTALS.values())


def write_fixtures(root):
    for rel, text in FIXTURES.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)


def long_paste(seed, kb=8, service="ledger-sync"):
    """A realistic pasted incident log with one failing service."""
    rnd = random.Random(seed)
    out = ["Here is the log from last night's deploy (pasted):", "```"]
    svcs = ["api-gateway", "auth", "billing", "search-index", "notifier"]
    i = 0
    while sum(len(l) + 1 for l in out) < kb * 1024:
        svc = rnd.choice(svcs)
        out.append(f"2026-10-0{1 + i % 8}T0{i % 10}:{i % 60:02d}:{(i * 7) % 60:02d}Z INFO {svc} handled batch {i} in {rnd.randint(5, 400)}ms (shard {rnd.randint(0, 31)})")
        if i % 37 == 20:
            out.append(f"2026-10-0{1 + i % 8}T0{i % 10}:{i % 60:02d}:59Z ERROR {service} reconcile failed: deadlock detected on table ledger_entries (attempt {i // 37 + 1} of 5)")
        i += 1
    out.append(f"2026-10-08T04:00:00Z FATAL {service} giving up after 5 attempts; pager notified")
    out.append("```")
    return "\n".join(out)


# ---------------------------------------------------------------- checks

def _has(text, *needles):
    low = text.lower()
    return all(n.lower() in low for n in needles)


def _number(text, n):
    return re.search(rf"(?<![\d.]){n}(?:\.0+)?(?![\d.])", text.replace(",", "")) is not None


def _three_primes(text):
    nums = [int(x) for x in re.findall(r"\b\d{3,5}\b", text)]
    def prime(k):
        return k > 1 and all(k % d for d in range(2, int(k ** 0.5) + 1))
    return len([k for k in nums if k > 100 and prime(k)]) >= 3


# ---------------------------------------------------------------- smoke

CODENAME = "AMBER-HERON-42"


def smoke_turns():
    t = []
    def add(tid, gap, kind, text, check=None, **kw):
        t.append(dict(id=tid, gap=gap, kind=kind, text=text, check=check, **kw))
    add("s01", 0, "short", f"Hello. For this test session remember this: the deploy codename is {CODENAME}. Reply with one word: noted.", ["has", "noted"])
    add("s02", 0, "short", "Name three prime numbers above 100 on one line.", ["primes"])
    add("s03", 30, "short", "Reply with exactly one word: OK", ["has", "ok"])
    add("s04", 0, "paste", long_paste(4) + "\n\nSummarize the failure in one sentence and name the failing service.", ["has", "ledger-sync"])
    add("s05", 0, "tool", "In the directory {work}, create the file parity/notes.txt with three lines: alpha, beta, gamma. Then run `wc -l parity/notes.txt` with your shell tool and tell me the line count it printed.", ["num", 3])
    add("s06", 30, "recall", "What was the deploy codename I gave you at the start of this session? Only the codename.", ["has", CODENAME], age="13 turns")
    add("s07", 360, "short", "Reply with exactly one word: BACK", ["has", "back"])
    add("s08", 0, "tool", "Using a shell command, count the lines that contain ERROR in {work}/fixtures/app.log. Reply with the number.", ["num", 17])
    add("s09", 0, "recall", "In the deploy log I pasted earlier, which service failed? One word.", ["has", "ledger-sync"], age="5 turns")
    add("s10", 30, "tool", "Read {work}/fixtures/config.toml and tell me the value of max_connections. Number only.", ["num", 384])
    add("s11", 0, "short", "What is 17 * 23? Number only.", ["num", 391])
    add("s12", 0, "subagent",
        "Use three subagents in parallel, one per file: {work}/fixtures/sub/a.py, {work}/fixtures/sub/b.py and {work}/fixtures/sub/c.py. "
        "Each subagent reports how many functions its file defines (lines that start with `def `) and the longest function name. "
        "When all three reports are in, combine them into one short table and give the total number of functions.",
        ["all", ["num", 16], ["has", "merge_overlapping_ranges"]], agents=3)
    add("s13", 20, "followup", "Quick question while that runs: what is the capital of France? One word.", ["has", "paris"],
        during="s12")
    add("s14", 0, "subagent",
        "Use two subagents in parallel: one counts the lines that contain TODO in {work}/fixtures/sub2/x.md, the other does the same for {work}/fixtures/sub2/y.md. "
        "Combine their reports: give each count and the total.", ["all", ["num", 3], ["num", 6], ["num", 9]], agents=2)
    add("s15", 30, "subagent",
        "Use three subagents in parallel, one per CSV file in {work}/fixtures/sub3/ (q1.csv, q2.csv, q3.csv). Each one sums the amount column of its file. "
        "Then give me the three sums and the grand total.", ["all", ["num", CSV_GRAND]] + [["num", v] for v in CSV_TOTALS.values()], agents=3)
    add("s16", 0, "recall", "In the first subagent analysis, which file defined the most functions? File name only.", ["has", "b.py"], age="4 turns")
    add("s17", 30, "recall", "What line count did you report for parity/notes.txt earlier?", ["num", 3], age="12 turns")
    add("s18", 0, "recall", "Last check: what is the deploy codename from the start of this session?", ["has", CODENAME], age="17 turns")
    return t


# ---------------------------------------------------------------- soak corpus

# CHIEF_PARITY_VARIANT=N (N >= 2) makes an independent copy of the corpus for a memory that already
# holds copy 1: project names get the suffix N, planted values change, dates move N-1 months back and
# session ids change, so its facts never collide with copy 1's. Same structure, same fact positions.
VARIANT = int(os.environ.get("CHIEF_PARITY_VARIANT", "1") or 1)
_SFX = "" if VARIANT <= 1 else str(VARIANT)
PROJECTS = [p + _SFX for p in ["kestrel", "osprey", "lynx", "marten", "heron", "otter", "falcon", "badger"]]
# Facts planted in the import: (message index in the corpus, question, answer).
IMPORT_FACTS = [
    (310, f"the staging database port for project kestrel{_SFX}", "6143" if VARIANT <= 1 else str(6143 + 1000 * VARIANT)),
    (1004, f"the name of the feature flag that gates the osprey{_SFX} billing rewrite", f"osprey{_SFX}_billing_v2"),
    (1500, f"the on-call rotation tool we chose for lynx{_SFX}", "rotabot" if VARIANT <= 1 else f"rotabot{VARIANT}"),
    (1950, f"the Redis eviction policy we settled on for marten{_SFX}", "allkeys-lfu" if VARIANT <= 1 else ["volatile-lru", "allkeys-lru", "volatile-ttl"][VARIANT % 3]),
]
CORPUS_MESSAGES = 2000


def _corpus_pair(rnd, i, proj):
    """One user message and one assistant reply (2 corpus messages)."""
    kind = rnd.random()
    fn = f"{rnd.choice(['load', 'sync', 'merge', 'flush', 'parse', 'render'])}_{rnd.choice(['config', 'ledger', 'cache', 'events', 'index'])}"
    if kind < 0.45:
        user = f"In {proj}, {rnd.choice(['why does', 'can you fix', 'please review', 'explain'])} {fn} in src/{proj}/{fn}.rs? It {rnd.choice(['panics on empty input', 'is slow on large batches', 'returns stale data', 'leaks a file handle'])}."
        reply = (f"I read src/{proj}/{fn}.rs. The problem: {rnd.choice(['the loop never checks for an empty slice', 'it clones the whole map per item', 'the cache key omits the tenant id', 'the handle is opened twice'])}. "
                 f"I changed it and ran `cargo test -p {proj}`: {rnd.randint(20, 300)} passed, 0 failed.\n\n```rust\nfn {fn}(input: &[u8]) -> Result<Vec<u8>> {{\n    if input.is_empty() {{ return Ok(Vec::new()); }}\n    let mut out = Vec::with_capacity(input.len());\n    out.extend_from_slice(input);\n    Ok(out)\n}}\n```")
    elif kind < 0.7:
        user = f"Decision time for {proj}: {rnd.choice(['Postgres or SQLite for the local store', 'gRPC or JSON over HTTP for the agent link', 'one queue per tenant or a shared queue', 'retry in the client or in the server'])}?"
        reply = f"For {proj} I recommend {rnd.choice(['SQLite', 'JSON over HTTP', 'a shared queue with tenant fairness', 'retry in the server'])}: {rnd.choice(['fewer moving parts', 'easier to debug', 'the load is small', 'one owner of the policy'])}. Trade-off: {rnd.choice(['less concurrency', 'larger payloads', 'a noisy tenant can delay others', 'clients wait longer'])}. Recorded in docs/{proj}/decisions.md."
    elif kind < 0.9:
        user = f"Run the {proj} test suite and tell me what fails."
        fails = rnd.randint(0, 3)
        out = "\n".join(f"test {proj}::{rnd.choice(['store', 'net', 'ui', 'cli'])}::case_{k} ... {'FAILED' if k < fails else 'ok'}" for k in range(rnd.randint(6, 14)))
        reply = f"I ran `cargo test -p {proj}`:\n\n```\n{out}\n```\n\n{fails} failing. " + ("Nothing to fix." if fails == 0 else f"The failures share one cause: a fixture path changed in commit {rnd.getrandbits(28):07x}.")
    else:
        user = f"Here is the panic from {proj} production, what happened?\n```\n" + "\n".join(
            f"   {k}: {proj}::{rnd.choice(['worker', 'pool', 'codec', 'router'])}::{rnd.choice(['run', 'poll', 'decode', 'dispatch'])}\n             at src/{proj}/{rnd.choice(['worker', 'pool'])}.rs:{rnd.randint(10, 900)}"
            for k in range(rnd.randint(8, 24))) + "\n```"
        reply = f"The panic comes from an index out of bounds in {proj}'s {rnd.choice(['decoder', 'pool', 'router'])} when a frame is shorter than its header. I added a length check and a regression test."
    return user, reply


def corpus_messages():
    """The 2,000 corpus messages in order: [(kind, text, iso date, session)]."""
    rnd = random.Random(2026)
    msgs = []
    facts = {idx: (q, a) for idx, q, a in IMPORT_FACTS}
    session = 0
    minute = 0
    i = 0
    while len(msgs) < CORPUS_MESSAGES:
        if i % 50 == 0:
            session += 1
            minute += 60 * 20
        proj = PROJECTS[session % len(PROJECTS)]
        user, reply = _corpus_pair(rnd, i, proj)
        if len(msgs) in facts or len(msgs) + 1 in facts:
            q, a = facts.get(len(msgs)) or facts[len(msgs) + 1]
            user = f"Note for later: {q} is {a}. Please confirm."
            reply = f"Noted: {q} is {a}."
        minute += rnd.randint(1, 6)
        day, rem = divmod(minute, 24 * 60)
        date = f"2026-{8 - (VARIANT - 1 if VARIANT > 1 else 0):02d}-{1 + day % 28:02d}T{rem // 60:02d}:{rem % 60:02d}:00.000Z"
        msgs.append(("user", user, date, session))
        msgs.append(("assistant", reply, date.replace(":00.000Z", ":30.000Z"), session))
        i += 1
    return msgs[:CORPUS_MESSAGES]


def write_corpus(root):
    """Claude Code projects JSONL (one session per file) under root/projects."""
    by_session = {}
    for kind, text, date, session in corpus_messages():
        by_session.setdefault(session, []).append((kind, text, date))
    total = 0
    for session, rows in by_session.items():
        proj = PROJECTS[session % len(PROJECTS)]
        cwd = f"/work/{proj}"
        d = os.path.join(root, "projects", f"-work-{proj}")
        os.makedirs(d, exist_ok=True)
        sid = hashlib.sha256((f"s{session}" if VARIANT <= 1 else f"v{VARIANT}s{session}").encode()).hexdigest()
        sid = f"{sid[:8]}-{sid[8:12]}-{sid[12:16]}-{sid[16:20]}-{sid[20:32]}"
        with open(os.path.join(d, f"{sid}.jsonl"), "w") as f:
            for k, (kind, text, date) in enumerate(rows):
                uid = hashlib.sha256((f"{session}:{k}" if VARIANT <= 1 else f"v{VARIANT}:{session}:{k}").encode()).hexdigest()[:32]
                content = text if kind == "user" else [{"type": "text", "text": text}]
                f.write(json.dumps({"type": kind, "uuid": uid, "sessionId": sid, "cwd": cwd, "timestamp": date,
                                    "message": {"role": kind, "content": content}}) + "\n")
                total += 1
    return total


# ---------------------------------------------------------------- soak turns

def soak_turns():
    rnd = random.Random(99)
    t = []
    pending = []  # (ask_at_turn, question, answer, age label)
    def add(tid, gap, kind, text, check=None, **kw):
        t.append(dict(id=tid, gap=gap, kind=kind, text=text, check=check, **kw))
    # Soak-start facts, asked at several later points.
    start_facts = [("the codename of the soak run", "SILVER-OTTER-7"),
                   ("the port of the soak metrics server", "9471"),
                   ("the soak owner's favourite test fixture", "fixtures/config.toml")]
    import_q = {30: 0, 45: 1, 70: 2, 85: 3, 100: 0, 105: 2}
    six_min = {15, 35, 55, 75, 95}
    hour = {40: 3720, 80: 3720}
    subagent_at = {50: "sub", 51: "followup", 90: "sub2"}
    for n in range(1, 111):
        tid = f"k{n:03d}"
        gap = hour.get(n) or (360 if n in six_min else rnd.choice([0, 0, 0, 30, 30]))
        if n <= 3:
            q, a = start_facts[n - 1]
            add(tid, gap, "fact", f"Remember for later: {q} is {a}. Reply with one word: noted.", ["has", "noted"])
            continue
        due = [p for p in pending if p[0] == n]
        if due:
            _, q, a, age = due[0]
            pending.remove(due[0])
            add(tid, gap, "recall", f"Recall question: what is {q}? Answer with the value only.", ["has", a], age=age)
            continue
        if n in (60, 100, 108):
            q, a = start_facts[{60: 0, 100: 1, 108: 2}[n]]
            add(tid, gap, "recall", f"From the start of this soak: what is {q}? Answer with the value only.", ["has", a], age=f"{n - 1 - (start_facts.index((q, a)))} turns (soak start)")
            continue
        if n in import_q:
            idx, q, a = IMPORT_FACTS[import_q[n]]
            add(tid, gap, "recall", f"From my older imported chats: what is {q}? Answer with the value only.", ["has", a],
                age=f"import msg {idx} of {CORPUS_MESSAGES} ({CORPUS_MESSAGES - idx} msgs before import end)")
            continue
        if subagent_at.get(n) == "sub":
            s = smoke_turns()[11]
            add(tid, gap, "subagent", s["text"], s["check"], agents=3)
            continue
        if subagent_at.get(n) == "followup":
            add(tid, 20, "followup", "While they work: what is 12 squared? Number only.", ["num", 144], during=f"k{n - 1:03d}")
            continue
        if subagent_at.get(n) == "sub2":
            s = smoke_turns()[13]
            add(tid, gap, "subagent", s["text"], s["check"], agents=2)
            continue
        if n % 10 == 4:
            val = rnd.randint(1000, 9999)
            q = f"the build number of release R{n}"
            add(tid, gap, "fact", f"Remember: {q} is {val}. Reply with one word: noted.", ["has", "noted"])
            pending.append((n + 5, q, str(val), "5 turns"))
            continue
        if n % 8 == 2:
            choice = n % 3
            if choice == 0:
                add(tid, gap, "tool", "Using a shell command, count the lines that contain ERROR in {work}/fixtures/app.log. Number only.", ["num", 17])
            elif choice == 1:
                add(tid, gap, "tool", "Read {work}/fixtures/config.toml and tell me the value of idle_timeout_s. Number only.", ["num", 90])
            else:
                add(tid, gap, "tool", f"In {{work}}, write the file soak/t{n}.txt containing the single line 'turn {n}', then run `cat soak/t{n}.txt` and tell me what it printed.", ["has", f"turn {n}"])
            continue
        if n % 12 == 7:
            add(tid, gap, "paste", long_paste(n, kb=rnd.choice([4, 8, 12])) + "\n\nWhich service hit the FATAL line? One word.", ["has", "ledger-sync"])
            continue
        a, b = rnd.randint(11, 99), rnd.randint(11, 99)
        add(tid, gap, "short", f"What is {a} * {b}? Number only.", ["num", a * b])
    return t


def interrupt_turns(reps=3):
    """A needs 3+ tool calls; B is sent 2 s and C 5 s after A, while A runs."""
    t = []
    for k in range(1, reps + 1):
        a = f"i{k}a"
        t.append(dict(id=a, gap=30 if k > 1 else 0, kind="interrupt", check=["all", ["num", 17], ["num", 384], ["num", 7]],
                      text="Run three separate shell commands, one at a time, and wait for each result before the next: "
                           "(1) count the lines containing ERROR in {work}/fixtures/app.log, "
                           "(2) print the max_connections line of {work}/fixtures/config.toml, "
                           "(3) count the lines starting with `def ` in {work}/fixtures/sub/b.py. Then report the three numbers."))
        t.append(dict(id=f"i{k}b", gap=2, kind="interrupt-b", during=a, check=["num", 42 + k],
                      text=f"Also, while you work: what is 6 * 7 + {k}? Number only."))
        t.append(dict(id=f"i{k}c", gap=5, kind="interrupt-c", during=a, check=["has", "blue"],
                      text="And one more: the color of a clear daytime sky, in one word."))
    return t


def codex6_turns():
    """6 short turns 20-30 s apart (warm cache check on any engine)."""
    return [dict(id=f"c{n}", gap=0 if n == 1 else (20 if n % 2 else 30), kind="short", check=["all", ["num", n], ["has", "ok"]],
                 text=f"Reply with the number {n} and the word ok.") for n in range(1, 7)]


def effort_turns():
    """On an already built import memory: 2 old-fact recalls, 5 recent facts set and recalled, 10 normal turns."""
    rnd = random.Random(5)
    t = []
    facts = [(f"the access code of locker {k}", str(rnd.randint(1000, 9999))) for k in range(1, 6)]
    def add(tid, kind, text, check, age=None):
        t.append(dict(id=tid, gap=0 if not t else 20, kind=kind, text=text, check=check, age=age))
    for k, (q, a) in enumerate(facts, 1):
        add(f"e-f{k}", "fact", f"Remember: {q} is {a}. Reply with one word: noted.", ["has", "noted"])
    for k in range(1, 6):
        a, b = rnd.randint(11, 99), rnd.randint(11, 99)
        add(f"e-n{k}", "short", f"What is {a} * {b}? Number only.", ["num", a * b])
    idx, q, a = IMPORT_FACTS[0]
    add("e-old1", "recall", f"From my older imported chats: what is {q}? Answer with the value only.", ["has", a], age=f"import msg {idx}")
    for k in range(6, 9):
        a, b = rnd.randint(11, 99), rnd.randint(11, 99)
        add(f"e-n{k}", "short", f"What is {a} * {b}? Number only.", ["num", a * b])
    for k, (q, a) in enumerate(facts, 1):
        add(f"e-r{k}", "recall", f"Recall question: what is {q}? Answer with the value only.", ["has", a], age="recent")
    idx, q, a = IMPORT_FACTS[1]
    add("e-old2", "recall", f"From my older imported chats: what is {q}? Answer with the value only.", ["has", a], age=f"import msg {idx}")
    for k in range(9, 11):
        a, b = rnd.randint(11, 99), rnd.randint(11, 99)
        add(f"e-n{k}", "short", f"What is {a} * {b}? Number only.", ["num", a * b])
    return t


def warm20_turns():
    """20 short turns 20-30 s apart on a fresh chat (warm cache read per turn)."""
    return [dict(id=f"w{n:02d}", gap=0 if n == 1 else (20 if n % 2 else 30), kind="short", check=["num", n * 7],
                 text=f"What is {n} * 7? Number only.") for n in range(1, 21)]


def refrecall_turns():
    """After an import: one recall turn per planted import fact (oldest first), 30 s apart."""
    return [dict(id=f"q{k}", gap=0 if k == 1 else 30, kind="recall", check=["has", a], age=f"import msg {i} of {CORPUS_MESSAGES}",
                 text=f"From my older imported chats: what is {q}? Answer with the value only.")
            for k, (i, q, a) in enumerate(IMPORT_FACTS, 1)]


def slow3_turns():
    """The three slowest first answers of the 2026-10-09 hard round, for a same-message comparison."""
    return [
        dict(id="x-work0", gap=0, kind="tool", check=["num", 6],
             text="Create {work}/proj/stats.py with a function mean(xs) that returns the average of a list, and a main that prints mean([3, 5, 10]). Run it with python3 and tell me the output."),
        dict(id="x-spawn", gap=20, kind="subagent", check=None,
             text="Spawn three subagents named after their files, one per file: count the lines in {work}/fixtures/sub/a.py, {work}/fixtures/sub/b.py and {work}/fixtures/sub/c.py. Tell me their names as soon as they start; do not wait for their reports in this reply."),
        dict(id="x-tool", gap=60, kind="tool", check=["has", "tool-kill-ok"],
             text="Run `sleep 8; echo tool-kill-ok` with your shell tool and tell me what it printed."),
    ]


def chiefux_turns():
    """Chief speed and delegation (hq-6d, 2026-10-14): a short ask, a 3-ask
    burst, one message with three tool-heavy asks (the 8-asks-in-3-minutes
    case of the Chief review), and one long ask. Uses only the fixtures."""
    t = []
    def add(tid, gap, kind, text, check=None, **kw):
        t.append(dict(id=tid, gap=gap, kind=kind, text=text, check=check, **kw))
    add("u01", 0, "short", "Reply with exactly one word: OK", ["has", "ok"])
    add("u02", 20, "short", "What is 17 * 23? Number only.", ["num", 391])
    add("u03a", 20, "burst", "What is 12 * 12? Number only.", ["num", 144])
    add("u03b", 1, "burst-b", "Also: the capital of Japan, one word.", ["has", "tokyo"], during="u03a")
    add("u03c", 2, "burst-c", "And the largest planet of the solar system, one word.", ["has", "jupiter"], during="u03a")
    add("u04", 20, "multi",
        "Three separate things, please: "
        "(1) for each of {work}/fixtures/sub/a.py, b.py and c.py, count the lines that start with `def `; "
        "(2) count the lines containing ERROR in {work}/fixtures/app.log; "
        "(3) sum the amount column of each CSV in {work}/fixtures/sub3/ and give the grand total. "
        "Report all the numbers.",
        ["all", ["num", 4], ["num", 7], ["num", 5], ["num", 17], ["num", CSV_GRAND]])
    add("u05", 20, "long",
        "Go through every file under {work}/fixtures (all subfolders), read each one, and write a one-line summary of each "
        "into {work}/parity/inventory.md. Then tell me how many files you summarized.", ["num", 10])
    # The review's heavy case (36 tool calls in one Chief turn): 30+ separate commands.
    add("u06", 20, "heavy",
        "Audit {work}/fixtures: for each of its 10 files (all subfolders) run three separate shell commands, one per tool call: "
        "`wc -l`, `wc -w` and `shasum -a 256`. Then write a table of all the results into {work}/parity/audit.md "
        "and tell me the total line count of the 10 files.", ["num", 349])
    return t


def turns(name):
    return {"smoke": smoke_turns, "soak": soak_turns, "interrupt": interrupt_turns, "codex6": codex6_turns, "import": list, "effort": effort_turns, "warm20": warm20_turns, "refimport": refrecall_turns, "slow3": slow3_turns, "chiefux": chiefux_turns}[name]()


def check(turn, reply):
    def ev(c):
        if c is None:
            return None
        op = c[0]
        if op == "has":
            return _has(reply, *c[1:])
        if op == "num":
            return _number(reply, c[1])
        if op == "primes":
            return _three_primes(reply)
        if op == "all":
            return all(ev(x) for x in c[1:])
        raise ValueError(op)
    return ev(turn.get("check"))


def main():
    cmd = sys.argv[1]
    if cmd == "turns":
        print(json.dumps(turns(sys.argv[2])))
    elif cmd == "fixtures":
        write_fixtures(sys.argv[2])
    elif cmd == "corpus":
        print(json.dumps({"messages": write_corpus(sys.argv[2])}))
    elif cmd == "check":
        tid, reply_file = sys.argv[2], sys.argv[3]
        allt = {x["id"]: x for x in smoke_turns() + soak_turns() + interrupt_turns() + codex6_turns() + effort_turns() + warm20_turns() + refrecall_turns() + slow3_turns()}
        print(json.dumps({"ok": check(allt[tid], open(reply_file).read())}))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
