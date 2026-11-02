#!/usr/bin/env python3
"""Drive our Chief (optchat-chief) on a scratch brain through one scenario.
(This file is the only copy: other parity harnesses load it from here.)

Runs on a build host, never on the laptop. Starts the
production trio on a scratch brain home, exactly as the always-on brain runs
(deploy/brain/install.sh), but as plain child processes of this script:
  cmux-tui --headless (the session daemon that owns the Chief conversation)
  optchat-chief host (which starts the brain's own acpmux under ACPMUX_HOME)
Human messages go into the Chief conversation as `user_local` through the
daemon socket, as the app's composer does. Numbers come from the host's own
trace ($MUX_HOME/optchat/traces) and the conversation.

Never touches a live brain: every path is under a new scratch directory, the
memory backup push is off, and only processes this script started (and the
brain's own acpmux, stopped through its own CLI) are stopped.

usage: chief_driver.py --scenario smoke|soak|coordinator --out DIR --bins DIR [--login-env FILE] [--harness claude]
  --bins       dir with optchat-chief, cmux-tui, acpmux (build-chief-bins.sh)
  --login-env  KEY=VALUE file whose ANTHROPIC_OAUTH_TOKEN (or
               CLAUDE_CODE_OAUTH_TOKEN) signs Claude Code in; read into the
               host's environment only, never printed. Deleted at the end
               when --delete-login-env is given.
"""
import argparse
import json
import re
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import secrets

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scenario  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--scenario", required=True, choices=["smoke", "soak", "interrupt", "codex6", "import", "effort", "warm20", "chiefux", "coordinator"])
ap.add_argument("--out", required=True)
ap.add_argument("--bins", required=True)
ap.add_argument("--login-env", default="")
ap.add_argument("--delete-login-env", action="store_true")
ap.add_argument("--harness", default="claude")
ap.add_argument("--turn-timeout", type=float, default=900)
ap.add_argument("--import-timeout", type=float, default=4 * 3600)
ap.add_argument("--only", default="")
ap.add_argument("--max-settle", type=float, default=None, help="stop the run when a turn waits longer than this on settle (s; 0: never)")
ap.add_argument("--mux-from", default="", help="start from a copy of this built memory (a kept MUX dir) instead of an empty one")
ap.add_argument("--turns-during-import", type=int, default=0, help="import scenario: send this many short turns, one per minute, while the import builds")
ap.add_argument("--keep-mux", default="", help="at the end, copy the brain's MUX dir (memory, traces) here")
ap.add_argument("--env", action="append", default=[], help="KEY=VALUE for the host (and so every turn and node); recorded in run.json")
opts = ap.parse_args()
# SIGTERM, SIGINT (Ctrl-C) and SIGHUP (a closed ssh session) run the cleanup
# below (stops what this script started, the brain's acpmux daemon too).
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))
if opts.max_settle is None:
    # A soak records a long first wait after its import instead of stopping on it.
    opts.max_settle = 1800 if opts.scenario == "soak" else 60

OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
BINS = os.path.abspath(opts.bins)
WORK = os.path.join(OUT, "work")
os.makedirs(WORK, exist_ok=True)
scenario.write_fixtures(WORK)
# Short: the daemon and tools sockets must fit sun_path.
BRAIN = tempfile.mkdtemp(prefix="cpb.", dir="/tmp")
SOCK = os.path.join(BRAIN, "daemon", "cmux.sock")
MUX = os.path.join(BRAIN, "mux")
TOOLS = os.path.join(MUX, "optchat", "tools.sock")
ACPMUX_HOME = os.path.join(BRAIN, "acpmux")
if opts.mux_from:
    shutil.copytree(opts.mux_from, MUX, ignore=shutil.ignore_patterns("*.sock", "*.lock", "traces", "settle.json"))
for d in ("daemon", "mux", "acpmux"):
    os.makedirs(os.path.join(BRAIN, d), exist_ok=True)
pids = []


def acpmux_machine_name():
    """Match acpmux's peer name for this host without naming a host in code."""
    first = socket.gethostname().split(".", 1)[0].lower()
    return first if re.fullmatch(r"[a-z0-9][a-z0-9_-]*", first or "") else "host"


def log(msg):
    print(f"[chief {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def now_ms():
    return int(time.time() * 1000)


def ask(req, timeout=30):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    s.connect(SOCK)
    req = dict(req, id=1)
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    out = json.loads(buf.decode())
    if not out.get("ok", True) and "data" not in out:
        raise RuntimeError(json.dumps(out)[:400])
    return out.get("data", out)


def ask_bound(participant, token, req, timeout=30):
    """Make one headless-daemon request as a non-owner conversation participant."""
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    s.connect(SOCK)

    next_id = 0

    def call(body):
        nonlocal next_id
        next_id += 1
        s.sendall((json.dumps(dict(body, id=next_id)) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        result = json.loads(buf.decode())
        if not result.get("ok", True) and "data" not in result:
            raise RuntimeError(json.dumps(result)[:400])
        return result.get("data", result)

    call({"cmd": "conversation-bind", "participant": participant, "token": token})
    out = call(req)
    s.close()
    return out


def inspect(path, query=None):
    try:
        return ask({"cmd": "chief-inspect", "path": path, **({"query": query} if query else {})}, timeout=20)
    except (OSError, RuntimeError, ValueError):
        return None


DRAIN = os.path.expanduser("~/nx-jobs/drain-window.json")


def wait_drain():
    """Pause while the build host holds a drain window (an idle host for someone's measurement)."""
    t = time.time()
    while True:
        try:
            active = json.load(open(DRAIN)).get("active")
        except (OSError, ValueError):
            active = None
        if not active:
            return round(time.time() - t)
        if time.time() - t < 1:
            log(f"drain window active ({str(active)[:120]}); pausing")
        time.sleep(15)


def login_env():
    env = {}
    if not opts.login_env:
        return env
    with open(opts.login_env) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.replace("export ", "").strip()
            v = v.strip().strip('"').strip("'")
            if k in ("ANTHROPIC_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"):
                env["CLAUDE_CODE_OAUTH_TOKEN"] = v
    return env


def lock_holders(path):
    """PIDs that hold `path` open (lsof), [] when none or no file."""
    if not os.path.exists(path):
        return []
    r = subprocess.run(["/usr/sbin/lsof", "-t", path], capture_output=True, text=True, timeout=20)
    return sorted({int(x) for x in r.stdout.split() if x.isdigit()})


def stop_acpmux():
    """Stop the brain's own acpmux daemon (the host started it under ACPMUX_HOME)
    and its local router if one started, through their own shutdown paths, then
    check that no process holds this home's locks. A holder left after that is
    this run's (the home is this run's alone): SIGTERM, then SIGKILL."""
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "ACPMUX_HOME": ACPMUX_HOME,
           "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}
    # The run's agents end with the daemon: `--end-agents` (cx-qryd0). An acpmux
    # from before that flag refuses it; its plain shutdown already ends agents.
    acp = os.path.join(BINS, "acpmux")
    try:
        r = subprocess.run([acp, "daemon", "shutdown", "--end-agents"], env=env, timeout=30, capture_output=True, text=True)
        if r.returncode != 0 and "end-agents" in (r.stdout + r.stderr):
            subprocess.run([acp, "daemon", "shutdown"], env=env, timeout=30, capture_output=True)
    except (OSError, subprocess.TimeoutExpired):
        pass
    router = os.path.join(ACPMUX_HOME, "router", "router.sock")
    if os.path.exists(router):
        try:
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(5)
                s.connect(router)
                s.sendall(b'{"op":"shutdown"}\n')
                s.recv(4096)
        except OSError:
            pass
    locks = [os.path.join(ACPMUX_HOME, "daemon.lock"), os.path.join(ACPMUX_HOME, "router", "router.lock")]
    left = []
    for step in ("wait", "term", "kill"):
        deadline = time.time() + (20 if step == "wait" else 5)
        while time.time() < deadline:
            try:
                left = sorted({p for lock in locks for p in lock_holders(lock)} - {os.getpid()})
            except (OSError, subprocess.TimeoutExpired):
                left = []
            if not left:
                break
            time.sleep(0.5)
        if not left or step == "kill":
            break
        for p in left:
            try:
                os.kill(p, signal.SIGTERM if step == "wait" else signal.SIGKILL)
            except ProcessLookupError:
                pass
    run["acpmux_left"] = left
    log(f"acpmux cleanup: home {ACPMUX_HOME}: {'no process holds its locks' if not left else 'STILL HELD by ' + str(left)}")


def cleanup():
    try:
        if run.get("conversation") and not os.path.exists(os.path.join(OUT, "conversation.json")):
            json.dump(ask({"cmd": "conversation-snapshot", "conversation": run["conversation"], "tail": 2000}, timeout=10),
                      open(os.path.join(OUT, "conversation.json"), "w"))
    except Exception:
        pass
    for p in reversed(pids):
        try:
            os.kill(p, signal.SIGTERM)
        except ProcessLookupError:
            pass
    stop_acpmux()
    for p in pids:
        try:
            os.waitpid(p, 0)
        except ChildProcessError:
            pass
    if opts.keep_mux and os.path.isdir(MUX) and not os.path.exists(opts.keep_mux):
        try:
            for root, _, files in os.walk(MUX):
                for f in files:
                    if f.endswith(".sqlite3"):
                        src = os.path.join(root, f)
                        subprocess.run(["sqlite3", src, ".backup " + src + ".kept"], capture_output=True, timeout=120)
            shutil.copytree(MUX, opts.keep_mux, ignore=shutil.ignore_patterns("*.sock", "*.lock"))
            for root, _, files in os.walk(opts.keep_mux):
                for f in files:
                    if f.endswith(".sqlite3.kept"):
                        os.replace(os.path.join(root, f), os.path.join(root, f[:-5]))
                        for ext in ("-wal", "-shm"):
                            if os.path.exists(os.path.join(root, f[:-5] + ext)):
                                os.remove(os.path.join(root, f[:-5] + ext))
        except Exception as e:
            print(f"keep-mux failed: {e}", flush=True)
    # Keep the evidence of a stopped run: traces and the conversation, before the brain dir goes.
    try:
        tr = os.path.join(MUX, "optchat", "traces")
        if os.path.isdir(tr) and not os.path.isdir(os.path.join(OUT, "traces")):
            shutil.copytree(tr, os.path.join(OUT, "traces"))
        if run.get("conversation") and not os.path.exists(os.path.join(OUT, "conversation.json")):
            snap = ask({"cmd": "conversation-snapshot", "conversation": run["conversation"], "tail": 2000}, timeout=10)
            json.dump(snap, open(os.path.join(OUT, "conversation.json"), "w"))
    except Exception:
        pass
    shutil.rmtree(BRAIN, ignore_errors=True)
    if opts.delete_login_env and opts.login_env and os.path.exists(opts.login_env):
        os.remove(opts.login_env)


try:
    _ccv = subprocess.run([os.path.expanduser("~/.local/bin/claude"), "--version"], capture_output=True, text=True, timeout=30).stdout.split()[0]
except (OSError, subprocess.TimeoutExpired, IndexError):
    _ccv = None
run = {"claude_code_version": _ccv, "side": "chief", "scenario": opts.scenario, "brain": BRAIN, "harness": opts.harness, "extra_env": opts.env, "pid": os.getpid()}
with open(os.path.join(OUT, "driver.pid"), "w") as f:
    f.write(str(os.getpid()))
try:
    rev = open(os.path.join(BINS, "REV")).read().strip() if os.path.exists(os.path.join(BINS, "REV")) else os.path.basename(BINS)
    run["build"] = rev
    oc = os.path.join(BINS, "optchat-chief")
    wait_drain()
    if opts.scenario in ("soak", "import"):
        corpus = os.path.join(OUT, "claude-config")
        scenario.write_corpus(corpus)
        t = time.time()
        r = subprocess.run([oc, "import-claude-code", "write", "--projects", os.path.join(corpus, "projects"), "--mux-home", MUX],
                           capture_output=True, text=True, env={"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin"})
        run["import_cli"] = {"rc": r.returncode, "out": (r.stdout + r.stderr)[-800:], "seconds": round(time.time() - t, 1)}
        log(f"import-claude-code: rc {r.returncode}: {(r.stdout + r.stderr).strip()[-300:]}")
        if r.returncode != 0:
            raise SystemExit("import failed")
    base_env = {"HOME": os.environ["HOME"], "PATH": f"{BINS}:{os.environ['HOME']}/.local/bin:{os.environ['HOME']}/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8", "USER": os.environ.get("USER", "cmux")}
    if opts.scenario == "coordinator":
        # Keep the proof isolated. The host reads this contact once at startup,
        # so write it before either production process starts. The target below
        # is a normal Claude ACP session on this scratch daemon, not a fake.
        os.makedirs(os.path.join(MUX, "optchat"), exist_ok=True)
        host_name = acpmux_machine_name()
        json.dump({"contact": f"{host_name}/synthetic-coord", "trace": {"full": True}},
                  open(os.path.join(MUX, "optchat", "settings.json"), "w"))
    daemon_log = open(os.path.join(OUT, "daemon.log"), "w")
    daemon_env = dict(base_env, CMUX_TUI_STATE_DIR=os.path.join(BRAIN, "daemon", "state"),
                      CMUX_TUI_CHIEF_TOOLS_SOCKET=TOOLS, ACPMUX_HOME=ACPMUX_HOME)
    if opts.scenario == "coordinator":
        daemon_env.update(dict(kv.split("=", 1) for kv in opts.env))
    d = subprocess.Popen([os.path.join(BINS, "cmux-tui"), "--headless", "--socket", SOCK], stdout=daemon_log, stderr=subprocess.STDOUT,
                         env=daemon_env)
    pids.append(d.pid)
    for _ in range(200):
        if os.path.exists(SOCK):
            break
        time.sleep(0.1)
    token = ask({"cmd": "conversation-agent-token", "participant": "agent_mux"})["token"]
    tok_file = os.path.join(BRAIN, "agent-token")
    fd = os.open(tok_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, token.encode())
    os.close(fd)
    host_env = dict(base_env, MUX_HOME=MUX, MUX_AGENT_TOKEN_FILE=tok_file, OPTCHAT_INSPECTOR="1", ACPMUX_HOME=ACPMUX_HOME,
                    ACPMUX_SOCKET=os.path.join(ACPMUX_HOME, "acpmux.sock"), ACPMUX_BIN=os.path.join(BINS, "acpmux"),
                    MUX_HARNESS=opts.harness, CMUX_DAEMON_SOCKET=SOCK, OPTCHAT_BACKUP_REMOTE="off", **login_env())
    scenario_env = dict(kv.split("=", 1) for kv in opts.env)
    host_env.update(scenario_env)
    host_started = now_ms()
    h = subprocess.Popen([oc, "host", "--daemon-socket", SOCK, "--mux-home", MUX], stdout=open(os.path.join(OUT, "host.log"), "w"),
                         stderr=subprocess.STDOUT, env=host_env)
    pids.append(h.pid)
    for _ in range(600):
        if os.path.exists(TOOLS) or h.poll() is not None:
            break
        time.sleep(0.1)
    if not os.path.exists(TOOLS):
        raise SystemExit("the host served no tools socket; see host.log")
    conv = None
    for _ in range(300):
        cl = ask({"cmd": "conversation-list"})["conversations"]
        conv = next((c["id"] for c in cl if any(p["id"] == "agent_mux" for p in c.get("participants", []))), None)
        if conv:
            break
        time.sleep(0.2)
    if not conv:
        raise SystemExit("no Chief conversation")
    run["conversation"] = conv
    # Brain cold start: host process start to its tools socket (the brain serves).
    run["brain_up_ms"] = now_ms() - host_started
    log(f"brain {BRAIN} up; conversation {conv}; harness {opts.harness}")

    TRACES = os.path.join(MUX, "optchat", "traces")

    def trace_events():
        out = []
        if not os.path.isdir(TRACES):
            return out
        for name in sorted(os.listdir(TRACES)):
            with open(os.path.join(TRACES, name)) as f:
                for line in f:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
        return out

    if opts.scenario == "import":
        # Import only: build until no node for 180 s; sample the RSS of the acpmux daemon's direct children every 10 s.
        t0 = now_ms()
        try:
            apid = int(re.findall(r"started acpmux daemon \S+ \(pid (\d+)", open(os.path.join(OUT, "host.log")).read())[0])
        except (OSError, IndexError, ValueError):
            apid = None
        peak, samples, last_node, seen = 0, [], time.time(), 0
        while time.time() - t0 / 1000 < opts.import_timeout:
            if apid:
                # Every descendant of the acpmux daemon (claude runs under one acpmux wrapper per session).
                tree, todo = set(), [apid]
                while todo:
                    q = todo.pop()
                    if q in tree:
                        continue
                    tree.add(q)
                    todo += [int(x) for x in subprocess.run(["pgrep", "-P", str(q)], capture_output=True, text=True).stdout.split()]
                tree.discard(apid)
                kids = [str(x) for x in tree]
                rss = 0
                if kids:
                    out = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(kids)], capture_output=True, text=True).stdout.split()
                    rss = sum(int(x) for x in out if x.isdigit()) * 1024
                samples.append((now_ms(), len(kids), rss))
                peak = max(peak, rss)
            k = len(run.setdefault("turns_during_import_sent", []))
            if k < opts.turns_during_import and time.time() - t0 / 1000 > 60 * (k + 1):
                try:
                    key = f"imp{k}-{now_ms()}"
                    ask({"cmd": "conversation-op", "conversation": conv, "idempotency_key": key, "actor": "user_local", "transaction": f"tx-{key}",
                         "op": {"kind": "message.send", "client_msg_id": key, "parts": [{"type": "text", "text": f"What is {k + 1} * 7? Number only."}]}})
                    run["turns_during_import_sent"].append(now_ms())
                except Exception as e:
                    run["turns_during_import_sent"].append(f"error {e}")
            n = sum(1 for e in trace_events() if e.get("ev") == "node" and e.get("ts", 0) >= t0)
            if n != seen:
                seen, last_node = n, time.time()
            elif n and time.time() - last_node > 180:
                break
            time.sleep(10)
        ev = trace_events()
        nodes = [e for e in ev if e.get("ev") == "node" and e.get("ts", 0) >= t0]
        hl = open(os.path.join(OUT, "host.log")).read()
        import metrics  # noqa: E402
        run["import"] = {"minutes": round((max([e["ts"] for e in nodes] or [t0]) - t0) / 60000, 1), "nodes": len(nodes),
                         "prompts": sum(e.get("prompts") or 0 for e in nodes), "failed": sum(1 for e in nodes if not e.get("ok")),
                         "tokens": {k: sum((e.get("usage") or {}).get(k) or 0 for e in nodes) for k in ("input", "cache_write", "cache_read", "output")},
                         "haiku_usd": round(sum(metrics.haiku_cost(e.get("usage"), e.get("prompts") or 1) for e in nodes if "haiku" in str(e.get("model"))), 3),
                         "acpmux_pid": apid, "peak_rss_bytes": peak, "peak_children": max([x[1] for x in samples] or [0]),
                         "capacity_events": sum(1 for e in ev if e.get("ev") == "compactor.capacity"),
                         "log_429_overloaded": sum(1 for l in hl.splitlines() if "429" in l or "overloaded" in l.lower())}
        tds, tde = [e for e in ev if e.get("ev") == "turn.start"], [e for e in ev if e.get("ev") == "turn.end"]
        run["import"]["turns_during"] = [{"settle_ms": a.get("settle_ms"), "view_bytes": (a.get("view") or {}).get("bytes"),
                                          "first_usage": b.get("first_usage"), "ms": b.get("ms")} for a, b in zip(tds, tde)]
        json.dump(samples, open(os.path.join(OUT, "rss-samples.json"), "w"))
        log(f"import: {json.dumps(run['import'])}")
    if opts.scenario == "soak":
        t0 = now_ms()
        last_unbuilt, last_change = None, time.time()
        while time.time() - t0 / 1000 < opts.import_timeout:
            st = inspect("/api/status") or {}
            ub = st.get("unbuilt")
            if ub == 0:
                break
            if ub != last_unbuilt:
                last_unbuilt, last_change = ub, time.time()
                log(f"import settle: unbuilt {ub}, view {st.get('view_bytes')} B / {st.get('view_lines')} lines")
            if time.time() - last_change > 600:
                log("import settle: no progress for 10 min, going on")
                break
            time.sleep(10)
        nodes = [e for e in trace_events() if e.get("ev") == "node" and e.get("ts", 0) >= t0]
        run["import"] = {"seconds": round((now_ms() - t0) / 1000, 1), "nodes": len(nodes),
                         "node_cost_usd": round(sum(e.get("cost_usd") or 0 for e in nodes), 4), "status": inspect("/api/status")}

    def messages_since(seq0):
        snap = ask({"cmd": "conversation-snapshot", "conversation": conv, "tail": 200})
        return [m for m in snap.get("messages", []) if m.get("seq", 0) > seq0]

    def last_seq():
        return ask({"cmd": "conversation-snapshot", "conversation": conv, "tail": 1})["conversation"].get("last_seq", 0)

    arrivals = {}  # message id -> first time this script saw it (ms)

    def poll_messages(seq0):
        out = messages_since(seq0)
        t = now_ms()
        for m in out:
            arrivals.setdefault(m["id"], t)
        return out

    def agent_texts(msgs):
        res = []
        for m in msgs:
            if m.get("author") != "agent_mux":
                continue
            text = "\n".join(p.get("text", "") for p in m.get("parts", []) if p.get("type") == "text")
            if text.strip():
                res.append((arrivals[m["id"]], m, text))
        return res

    def send(text, key):
        out = ask({"cmd": "conversation-op", "conversation": conv, "idempotency_key": key, "actor": "user_local",
                   "transaction": f"tx-{key}", "op": {"kind": "message.send", "client_msg_id": key,
                                                      "parts": [{"type": "text", "text": text}]}})
        return out.get("seq")

    def idle(t0):
        """Idle: no running turn, every spawn since t0 reported, quiet for 8 s."""
        ev = trace_events()
        recent = [e for e in ev if e.get("ts", 0) >= t0]
        started = [e for e in recent if e.get("ev") == "turn.start"]
        ended = [e for e in recent if e.get("ev") == "turn.end"]
        spawns = {e.get("spawn") for e in recent if e.get("ev") == "spawn"}
        reported = {e.get("spawn") for e in recent if e.get("ev") == "spawn.report"}
        if not started or len(ended) < len(started) or spawns - reported:
            return False
        last = max(e.get("ts", 0) for e in recent)
        return now_ms() - last > 8000

    def acp_cli(*args, timeout=30):
        """Run an isolated acpmux CLI command against this proof's daemon."""
        env = dict(base_env, ACPMUX_HOME=ACPMUX_HOME,
                   ACPMUX_SOCKET=os.path.join(ACPMUX_HOME, "acpmux.sock"))
        p = subprocess.run([os.path.join(BINS, "acpmux"), "--json", *args], env=env,
                           capture_output=True, text=True, timeout=timeout)
        if p.returncode:
            raise RuntimeError(f"acpmux {' '.join(args)} failed ({p.returncode}): {(p.stdout + p.stderr).strip()[-500:]}")
        try:
            return json.loads(p.stdout) if p.stdout.strip() else {}
        except ValueError:
            return {"text": p.stdout}

    def acp_tail(session, last=200):
        env = dict(base_env, ACPMUX_HOME=ACPMUX_HOME,
                   ACPMUX_SOCKET=os.path.join(ACPMUX_HOME, "acpmux.sock"))
        p = subprocess.run([os.path.join(BINS, "acpmux"), "session", "tail", session,
                            "--last", str(last)], env=env, capture_output=True, text=True,
                           timeout=30)
        if p.returncode:
            return []
        out = []
        for line in p.stdout.splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out

    def serialized(events):
        return [json.dumps(e, sort_keys=True) for e in events]

    def token_events(events, token):
        return [e for e, text in zip(events, serialized(events)) if token in text]

    def sender_values(value):
        found = []
        if isinstance(value, dict):
            meta = value.get("_meta") if isinstance(value.get("_meta"), dict) else {}
            provenance = meta.get("provenance") if isinstance(meta.get("provenance"), dict) else {}
            from_id = provenance.get("from")
            if isinstance(from_id, str):
                found.append({"sessionId": from_id})
            for parent in (meta, value):
                message = parent.get("_acpmuxMessage") if isinstance(parent, dict) else None
                sender = message.get("sender") if isinstance(message, dict) else None
                if isinstance(sender, dict) and "sessionId" in sender:
                    found.append(sender)
            mux = meta.get("acpmux")
            if isinstance(mux, dict) and "sender" in mux:
                found.append(mux["sender"])
            for child in value.values():
                found.extend(sender_values(child))
        elif isinstance(value, list):
            for child in value:
                found.extend(sender_values(child))
        return found

    def wait_turn(seq0, started):
        deadline = time.time() + opts.turn_timeout
        while time.time() < deadline:
            poll_messages(seq0)
            if idle(started):
                return True
            time.sleep(0.5)
        return False

    def chief_turn_sessions():
        # Turn sessions are deliberately short-lived and can rotate between
        # the owner's message and the coordinator's reply. Use the complete
        # local session list so a PONG in an earlier turn is still observed.
        rows = acp_cli("ls", "--all").get("sessions", [])
        return [r.get("sessionId") or r.get("id") or r.get("name")
                for r in rows
                if (r.get("tags") or {}).get("cmux.chief.role") == "turn"
                and (r.get("sessionId") or r.get("id") or r.get("name"))]

    def chief_turn_session():
        turns = chief_turn_sessions()
        return turns[-1] if turns else None

    def chief_pong_events(token):
        """Return PONG events from every Chief turn session in this run."""
        events = []
        for session in chief_turn_sessions():
            events.extend(e for e in acp_tail(session)
                          if token in "".join(serialized([e])))
        return events

    if opts.scenario == "coordinator":
        # The host has already started the isolated daemon. Create a normal
        # Claude ACP session on that daemon before sending the real Chief turn.
        acp_cli("new", "--model", "claude", "--name", "synthetic-coord", "--detach", "--cwd", WORK)
        run["coordinator_session"] = "synthetic-coord"
        token = "PING-" + secrets.token_hex(4).upper()
        pong = "PONG-" + secrets.token_hex(4).upper()
        owner_text = f"Send your coordinator the word {token}; tell me when its answer arrives."
        seq0 = last_seq()
        started = now_ms()
        send(owner_text, f"coordinator-owner-{started}")
        owner_ok = wait_turn(seq0, started)
        owner_msgs = agent_texts(poll_messages(seq0))
        owner_posted = bool(owner_msgs)
        chief_session = chief_turn_session()
        target_row = next((r for r in acp_cli("ls", "--live").get("sessions", [])
                           if r.get("name") == "synthetic-coord"), {})
        target_session = target_row.get("sessionId") or target_row.get("id")
        events = acp_tail("synthetic-coord")
        ping_events = token_events(events, token)
        if chief_session:
            ping_events = [e for e in ping_events
                           if any(isinstance(s, dict) and s.get("sessionId") == chief_session
                                  for s in sender_values(e))]
        sender = next((s for e in ping_events for s in sender_values(e)
                       if isinstance(s, dict)
                       and (chief_session is None or s.get("sessionId") == chief_session)), None)
        sender_id = sender.get("sessionId") if isinstance(sender, dict) else None
        ping_ok = bool(ping_events)
        provenance_ok = bool(sender_id and sender_id == chief_session)
        chief_pong = chief_pong_events(pong)
        pong_received = any(
            any(isinstance(s, dict) and s.get("sessionId") == target_session
                for s in sender_values(e))
            for e in chief_pong
        )
        pong_in_owner = any(
            pong.lower() in text.lower()
            for _, _message, text in owner_msgs
        )
        owner_posted = pong_received and pong_in_owner
        # A real model may finish its first turn before the target's inbox
        # reply arrives. Prompt the normal target once, then ask the owner to
        # read that reply, keeping the proof end to end.
        if not owner_posted:
            acp_cli("send", "synthetic-coord",
                    f"Read the Chief's latest message containing {token}. Reply to that Chief using acpmux_inbox_reply with exactly {pong}.",
                    timeout=max(30, int(opts.turn_timeout)))
            followup_seq = last_seq()
            followup_started = now_ms()
            send("Read your coordinator's reply and tell me when it arrived.",
                 f"coordinator-followup-{followup_started}")
            wait_turn(followup_seq, followup_started)
            chief_pong = chief_pong_events(pong)
            pong_received = any(
                any(isinstance(s, dict) and s.get("sessionId") == target_session
                    for s in sender_values(e))
                for e in chief_pong
            )
            pong_in_owner = any(
                pong.lower() in text.lower()
                for _, _message, text in agent_texts(poll_messages(seq0))
            )
            owner_posted = pong_received and pong_in_owner
            events = acp_tail("synthetic-coord")
            ping_events = token_events(events, token)
            if chief_session:
                ping_events = [e for e in ping_events
                               if any(isinstance(s, dict) and s.get("sessionId") == chief_session
                                      for s in sender_values(e))]
            sender = next((s for e in ping_events for s in sender_values(e)
                           if isinstance(s, dict)
                           and (chief_session is None or s.get("sessionId") == chief_session)), sender)
            sender_id = sender.get("sessionId") if isinstance(sender, dict) else None
            ping_ok = bool(ping_events)
            provenance_ok = bool(sender_id and sender_id == chief_session)
        log(f"COORDINATOR owner_reply_posted={'PASS' if owner_posted else 'FAIL'} token={pong}")
        log(f"COORDINATOR owner_turn_timeout={'YES' if not owner_ok else 'NO'}")
        log(f"COORDINATOR ping_readback={'PASS' if ping_ok else 'FAIL'} token={token}")
        log(f"COORDINATOR provenance_sender={'PASS' if provenance_ok else 'FAIL'} sender={sender_id or sender or 'missing'}")
        inventory = acp_cli("ls", "--live", "--with-tools").get("sessions", [])
        by_id = {r.get("sessionId"): r for r in inventory}
        chief_row = by_id.get(chief_session, {})
        target_row = next((r for r in inventory if r.get("name") == "synthetic-coord"), target_row)
        tool_list = {
            "chief": {"policy": chief_row.get("policy"), "tools": [t.get("id") for t in chief_row.get("tools", [])]},
            "target": {"policy": target_row.get("policy"), "tools": [t.get("id") for t in target_row.get("tools", [])]},
        }
        log(f"COORDINATOR tool_list={json.dumps(tool_list, sort_keys=True)}")

        ask_token = "ASK-" + secrets.token_hex(4).upper()
        ask_text = f"Use acpmux_send to forward this coordinator request: send the word {ask_token} and tell me when it's sent."
        # A Chief turn session is ephemeral; resolve the current one again
        # after the owner exchange instead of reusing an ended turn id.
        chief_session = chief_turn_session()
        if not chief_session:
            raise SystemExit("coordinator proof found no Chief turn session")
        # Make this a real ask-floor turn: the message author is another
        # conversation participant, rather than an acpmux inbox delivery to
        # the ephemeral turn session (which would remain an owner turn).
        ask_participant = "user_coordinator"
        ask({"cmd": "conversation-op", "conversation": conv,
             "idempotency_key": "coordinator-ask-participant",
             "actor": "user_local", "transaction": "tx-coordinator-ask-participant",
             "op": {"kind": "participants.add", "participant": {
                 "id": ask_participant, "kind": "human", "display_name": "Coordinator"}}})
        ask_token_credential = ask({"cmd": "conversation-agent-token", "participant": ask_participant})["token"]
        ask_started = now_ms()
        ask_bound(ask_participant, ask_token_credential,
                  {"cmd": "conversation-op", "conversation": conv,
                   "idempotency_key": f"coordinator-ask-{ask_started}",
                   "actor": ask_participant, "transaction": f"tx-coordinator-ask-{ask_started}",
                   "op": {"kind": "message.send", "client_msg_id": f"coordinator-ask-{ask_started}",
                          "parts": [{"type": "text", "text": "@agent_mux " + ask_text,
                                     "runs": [{"start": 0, "length": 10, "mention": "agent_mux"}]}]}})
        ask_ok = wait_turn(last_seq(), ask_started)
        ask_events = [e for e in trace_events()
                      if e.get("ev") == "tool" and e.get("ts", 0) >= ask_started
                      and "acpmux_send" in str(e.get("name", ""))
                      and e.get("ok") is False]
        ask_approvals = [e for e in trace_events()
                         if e.get("ev") == "approval" and e.get("ts", 0) >= ask_started
                         and "acpmux_send" in str(e.get("tool", ""))
                         and e.get("decision") == "deny"]
        ask_refused = bool(ask_events and ask_approvals)
        ask_coord_events = token_events(acp_tail("synthetic-coord"), ask_token)
        log(f"COORDINATOR ask_send_refused={'PASS' if ask_ok and ask_refused and not ask_coord_events else 'FAIL'} token={ask_token}")
        log(f"COORDINATOR ask_turn_timeout={'YES' if not ask_ok else 'NO'}")
        run["coordinator"] = {
            "token": token,
            "pong": pong,
            "ask_token": ask_token,
            "owner_reply_posted": owner_posted,
            "ping_readback": ping_ok,
            "provenance_sender": provenance_ok,
            "sender": sender,
            "chief_session": chief_session,
            "tool_list": tool_list,
            "ask_refused": ask_ok and ask_refused and not ask_coord_events,
        }
        json.dump(run, open(os.path.join(OUT, "run.json"), "w"), indent=1)
        if not all(run["coordinator"][key] for key in
                   ("owner_reply_posted", "ping_readback", "provenance_sender", "ask_refused")):
            raise SystemExit("coordinator proof failed")
        raise SystemExit(0)

    turns = scenario.turns(opts.scenario)
    if opts.only:
        keep = set(opts.only.split(","))
        turns = [t for t in turns if t["id"] in keep]
    results = []
    prev_end = time.time()
    for i, turn in enumerate(turns):
        if turn.get("during"):
            continue
        nxt = turns[i + 1] if i + 1 < len(turns) else None
        wait_s = turn["gap"] - (time.time() - prev_end)
        if wait_s > 0:
            log(f"gap {turn['gap']} s before {turn['id']}")
            time.sleep(wait_s)
        paused = wait_drain()
        if paused:
            log(f"drain pause {paused} s before {turn['id']}")
            run.setdefault("drain_pauses", []).append({"before": turn["id"], "s": paused})
        seq0 = last_seq()
        sent = {turn["id"]: now_ms()}
        send(turn["text"].replace("{work}", WORK), f"{turn['id']}-{sent[turn['id']]}")
        log(f"sent {turn['id']} ({turn['kind']})")
        group = [turn]
        for kid in sorted([t for t in turns if t.get("during") == turn["id"]], key=lambda t: t["gap"]):
            while time.time() < sent[turn["id"]] / 1000 + kid["gap"]:
                poll_messages(seq0)
                time.sleep(0.1)
            sent[kid["id"]] = now_ms()
            send(kid["text"].replace("{work}", WORK), f"{kid['id']}-{sent[kid['id']]}")
            log(f"sent {kid['id']} during {turn['id']}")
            group.append(kid)
        t_start = sent[turn["id"]]
        ok = False
        deadline = time.time() + opts.turn_timeout
        settle_since, stalled = None, None
        while time.time() < deadline:
            poll_messages(seq0)
            if idle(t_start):
                ok = True
                break
            st = inspect("/api/status") or {}
            if not st:
                # No inspector answer: the host log says when a turn waits on settle.
                try:
                    tail = open(os.path.join(OUT, "host.log")).read()[-20000:]
                except OSError:
                    tail = ""
                waits = [l for l in tail.splitlines() if "turn waits for the compactor" in l]
                if waits and time.mktime(time.strptime(waits[-1][:19], "%Y-%m-%d %H:%M:%S")) * 1000 >= t_start:
                    st = {"settle": waits[-1][24:200]}
            if st.get("settle"):
                settle_since = settle_since or time.time()
                if opts.max_settle and time.time() - settle_since > opts.max_settle:
                    stalled = {"turn": turn["id"], "waited_s": round(time.time() - settle_since), "settle": st.get("settle"),
                               "failures": st.get("failures"), "busy": st.get("busy")}
                    break
            else:
                settle_since = None
            time.sleep(0.5)
        msgs = poll_messages(seq0)
        prev_end = time.time()
        for g in group:
            results.append({"id": g["id"], "kind": g["kind"], "gap": g["gap"], "age": g.get("age"), "send_ms": sent[g["id"]],
                            "idle_ms": now_ms(), "timeout": not ok, "seq0": seq0,
                            "msgs": [{"t": t, "id": m["id"], "seq": m.get("seq"), "text": x[:4000]} for (t, m, x) in agent_texts(msgs)]})
        log(f"done {turn['id']} in {(now_ms() - t_start) / 1000:.1f} s")
        if stalled:
            run["blocker"] = f"turn {turn['id']} waited over {opts.max_settle:.0f} s on settle: {json.dumps(stalled)[:600]}"
            log("STOP: " + run["blocker"])
            break

    run["end"] = now_ms()
    run["status_end"] = inspect("/api/status")
    shutil.copytree(TRACES, os.path.join(OUT, "traces"), dirs_exist_ok=True)
    json.dump({"results": results}, open(os.path.join(OUT, "raw.json"), "w"), indent=1)
    json.dump(run, open(os.path.join(OUT, "run.json"), "w"), indent=1)
    import metrics  # noqa: E402
    results, run = metrics.chief(OUT)
    log(f"wrote {len(results)} turns; API-equivalent cost {run['cost_usd']} USD")
finally:
    cleanup()
