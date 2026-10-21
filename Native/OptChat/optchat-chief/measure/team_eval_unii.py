#!/usr/bin/env python3
"""Arm C of the coordinator-mode eval: real UniiChat, tree memory plus
background subagents (github.com/VictorTaelin/UniiChat at 0500bf6).

team_eval.py dispatches `--arm C` here (run_unii). A run is UniiChat as a
person self-hosts it, on a scratch UNII_DIR:

  - a COPY of the UniiChat source (never the clone itself), with one patch:
    Anthropic.ts hardcodes https://api.anthropic.com, so it points at a
    recording proxy in this process instead, which forwards every request to
    ANTHROPIC_BASE_URL from --env (the team route signs it; the key is the
    placeholder) and reads the usage each streamed response reports;
  - `bun Server.ts PORT` with UNII_PICK from OPTCHAT_CHIEF_MODEL/EFFORT and
    UNII_AGENTS from OPTCHAT_SUBAGENT_MODEL/EFFORT (else the Chief's); the
    compactor keeps UniiChat's own default (haiku-5.5, high), as the Chief
    arms keep theirs;
  - sign-in as UniiChat's terminal does it: POST /api/login {who, key}, the
    /auth?t= link the server prints (no Resend key), POST /auth {t, code};
  - one `bun Term.ts URL` terminal from a pipe: the device the agents' shell,
    read, write and edit run on. Its work dir's `main` (the agent's cwd) is
    the task repo, the stubs dir is first on its PATH; subagents work in
    their own WORK/<Name> dirs, as UniiChat does, and reach the repo by the
    absolute path the brief gives;
  - one more socket, a view like a browser tab, that records the server's
    events (state: busy and agents at work; entries) with their arrival time.

The brief and the follow-ups are posted as the person's messages (the
`say` act a terminal or tab posts, /api/act). The run ends on idle (nothing
busy, no agent at work, quiet for --quiet-seconds after the last follow-up),
on the budget (real spend, from the proxy's usage records) or the deadline.
Outputs are run_lossy's: run.json, conversation.json, traces/, diff.patch.
"""
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import team_eval  # noqa: E402
from unii_bench import PRICES  # noqa: E402  (in, cache write 1h, cache write 5m, cache read, out) per MTok

CHIEF = team_eval.CHIEF
UNII_COMMIT = "0500bf6"
UNII_SRC_DEFAULT = "/tmp/te-unii/src"
WHO = "eval@example.com"
# UniiChat's models (Pick.ts) by API id; it offers no others.
UNII_LABELS = {"claude-opus-5-5": "opus-5.5", "claude-sonnet-5-5": "sonnet-5.5", "claude-haiku-5-5": "haiku-5.5"}
EFFORTS = ("low", "medium", "high", "xhigh", "max")
SEARCH_USD = 0.01  # a web search, as Price.ts (Anthropic: $10 per 1,000)
ANTHROPIC = "https://api.anthropic.com"
SUB_HEAD = "You are a subagent of Unii"
HANDS_HEAD = "You are the hands of Unii"

OBSERVER_JS = r"""
// team_eval_unii observer: a view of the chat (a tab, no device) that prints
// every server event but the streamed pieces, with the ms it arrived.
const [url, token] = process.argv.slice(2);
const say = (msg) => process.stdout.write(JSON.stringify({ at: Date.now(), msg }) + "\n");
function open() {
  const ws = new WebSocket(url.replace(/^http/, "ws") + "/ws?tab=team-eval-observer&wire=2",
                           { headers: { authorization: "Bearer " + token } });
  ws.onmessage = (ev) => {
    const data = String(ev.data);
    if (data === "+") return;
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    if (msg.$ === "delta") return;
    say(msg);
  };
  ws.onclose = (ev) => { say({ $: "observer.closed", code: ev.code }); setTimeout(open, 1000); };
}
open();
"""


def now_ms():
    return int(time.time() * 1000)


# Pure parts ----------------------------------------------------------------

def unii_pick(model, effort):
    """UniiChat's pick (vendor:model:effort:speed) for the Chief's model and
    effort. UniiChat offers only its three Claude models; anything else is an
    error, not a silent swap."""
    model = (model or "claude-opus-5-5").strip()
    label = UNII_LABELS.get(model) or (model if model in UNII_LABELS.values() else None)
    if label is None:
        raise SystemExit(f"arm C: UniiChat {UNII_COMMIT} offers {sorted(UNII_LABELS)}, not {model}")
    effort = (effort or "medium").strip()
    if effort not in EFFORTS:
        raise SystemExit(f"arm C: UniiChat efforts are {EFFORTS}, not {effort}")
    return f"claude-api:{label}:{effort}:slow"


def price_of(model):
    """List prices (unii_bench.PRICES) for a model id; a model it lacks takes
    its family's entry there, and says so."""
    if model in PRICES:
        return PRICES[model], None
    for family in ("opus", "sonnet", "haiku"):
        if family in (model or ""):
            key = next(k for k in PRICES if family in k)
            return PRICES[key], f"{model} priced as {key}"
    return PRICES["claude-opus-5-5"], f"{model} priced as claude-opus-5-5"


def usage_cost(model, u):
    """Dollars of one response's usage at list prices. Cache writes split by
    TTL when the API says (cache_creation), else all at 5 minutes, which is
    what UniiChat marks ({type: ephemeral})."""
    (p_in, p_w1h, p_w5m, p_read, p_out), _ = price_of(model)
    write = u.get("cache_creation_input_tokens") or 0
    split = u.get("cache_creation") or {}
    w1h = split.get("ephemeral_1h_input_tokens") or 0
    w5m = split.get("ephemeral_5m_input_tokens")
    w5m = (write - w1h) if w5m is None else w5m
    searches = ((u.get("server_tool_use") or {}).get("web_search_requests")) or 0
    return ((u.get("input_tokens") or 0) * p_in + w5m * p_w5m + w1h * p_w1h
            + (u.get("cache_read_input_tokens") or 0) * p_read + (u.get("output_tokens") or 0) * p_out) / 1e6 \
        + searches * SEARCH_USD


def merge_usage(use, u):
    """Fold one event's usage into the running one, as Anthropic.ts usage():
    each field the latest told (message_delta repeats or grows them)."""
    for k, v in (u or {}).items():
        if v is not None:
            use[k] = v
    return use


def classify(body):
    """What a Messages request serves, from its body: a compaction has no
    tools; a subagent's (and a computer task's) system prompt is its own;
    the rest are the chat's turns."""
    if not isinstance(body, dict):
        return "other"
    system = body.get("system")
    text = system[0].get("text", "") if isinstance(system, list) and system and isinstance(system[0], dict) else str(system or "")
    if not body.get("tools"):
        return "compactor"
    if text.startswith(SUB_HEAD) or text.startswith(HANDS_HEAD):
        return "subagent"
    return "turn"


def cost_split(records):
    """cost_usd in run_lossy's keys from the proxy's records."""
    out = {"turns": 0.0, "subagents": 0.0, "compactor": 0.0}
    key = {"turn": "turns", "subagent": "subagents", "compactor": "compactor"}
    for r in records:
        if r.get("cost_usd") and r.get("kind") in key:
            out[key[r["kind"]]] += r["cost_usd"]
    out["all"] = sum(out.values())
    return {k: round(v, 4) for k, v in out.items()}


def join_pages(records):
    """UniiChat's main/ log lines as whole messages: a message is logged in
    pages, each but the last `more`; act records and other lines carry no
    kind. Returns [{i (first page), last (last page), kind, text, act, date}]."""
    out, cur = [], None
    for r in sorted((r for r in records if "kind" in r and "i" in r), key=lambda r: r["i"]):
        if cur is None:
            cur = {"i": r["i"], "last": r["i"], "kind": r["kind"], "text": r.get("text", ""), "act": r.get("act"),
                   "date": r.get("date")}
        else:
            cur["text"] += r.get("text", "")
            cur["last"] = r["i"]
            cur["act"] = r.get("act") or cur["act"]
        if not r.get("more"):
            out.append(cur)
            cur = None
    if cur is not None:
        out.append(cur)
    return out


def unii_messages(records, seen_at, after):
    """The conversation of a C run in the Chief run's shape: the person's
    messages (kind user) as user_local, Unii's replies (kind unii) as the
    agent. Agents' reports (kind work), tool calls and results stay in the
    traces, as a Chief's subagent answers do. `seen_at` maps a page index to
    the ms this run first saw it; `after`: the last index before the brief
    (UniiChat's own hello lines come first in every new chat)."""
    msgs, arrivals = [], {}
    for m in join_pages(records):
        if m["i"] <= after or m["kind"] not in ("user", "unii") or not m["text"].strip():
            continue
        mid = f"u{m['i']}"
        user = m["kind"] == "user"
        msgs.append({"id": mid, "seq": len(msgs) + 1, "author": "user_local" if user else CHIEF,
                     "client_msg_id": (m.get("act") or f"unii:{m['i']}") if user else f"unii:{m['i']}",
                     "parts": [{"type": "text", "text": m["text"]}]})
        arrivals[mid] = seen_at.get(m["last"], seen_at.get(m["i"], 0))
    return msgs, arrivals


def turns_of(states):
    """Unii's turns from the observer's state events: each rise of busy."""
    n, prev = 0, False
    for s in states:
        busy = bool(s.get("busy"))
        if busy and not prev:
            n += 1
        prev = busy
    return n


def sse_events(buf):
    """Complete `data:` JSON events in an SSE buffer and the rest of it."""
    out = []
    *lines, rest = buf.split("\n")
    for line in lines:
        line = line.strip()
        if line.startswith("data:"):
            try:
                out.append(json.loads(line[5:].strip()))
            except ValueError:
                pass
    return out, rest


def patch_source(src_dir, base_url):
    """The one change to the copy: Anthropic.ts's hardcoded API origin (the
    Messages and count_tokens URLs) to `base_url`. Returns the count patched;
    the run refuses a copy where it found none."""
    path = os.path.join(src_dir, "Anthropic.ts")
    with open(path) as f:
        text = f.read()
    n = text.count(ANTHROPIC)
    with open(path, "w") as f:
        f.write(text.replace(ANTHROPIC, base_url.rstrip("/")))
    return n


# The recording proxy -------------------------------------------------------

HOP = {"host", "content-length", "connection", "accept-encoding", "transfer-encoding", "keep-alive"}


class Proxy:
    """Forwards UniiChat's API calls to the route and records each response's
    usage and cost as it streams (records, api.jsonl)."""

    def __init__(self, upstream, log_path, extra_headers):
        self.upstream = upstream.rstrip("/")
        self.extra = extra_headers
        self.records = []
        self.lock = threading.Lock()
        self.log = open(log_path, "a")
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                proxy.forward(self)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def spent(self):
        with self.lock:
            return sum(r.get("cost_usd") or 0 for r in self.records)

    def snapshot(self):
        with self.lock:
            return [dict(r) for r in self.records]

    def forward(self, h):
        body = h.rfile.read(int(h.headers.get("content-length") or 0))
        try:
            req_json = json.loads(body)
        except ValueError:
            req_json = None
        rec = {"start_ms": now_ms(), "path": h.path, "model": (req_json or {}).get("model"),
               "kind": classify(req_json) if h.path.startswith("/v1/messages") and "count_tokens" not in h.path else "count",
               "usage": {}, "cost_usd": 0.0}
        if isinstance(req_json, dict):
            sysp = req_json.get("system")
            rec["system_head"] = (sysp[0].get("text", "") if isinstance(sysp, list) and sysp else str(sysp or ""))[:80]
            rec["tools"] = [t.get("name") for t in req_json.get("tools") or []]
            rec["effort"] = (req_json.get("output_config") or {}).get("effort")
        with self.lock:
            self.records.append(rec)
        headers = {k: v for k, v in h.headers.items() if k.lower() not in HOP}
        headers.update(self.extra)
        req = urllib.request.Request(self.upstream + h.path, data=body, headers=headers, method="POST")
        try:
            resp = urllib.request.urlopen(req, timeout=900)
        except urllib.error.HTTPError as e:
            resp = e
        except OSError as e:
            rec.update(status=0, error=str(e)[:300], end_ms=now_ms())
            self._write(rec)
            h.send_error(502, "team_eval_unii proxy: " + str(e)[:200])
            return
        rec["status"] = resp.status
        h.send_response(resp.status)
        for k, v in resp.headers.items():
            if k.lower() not in HOP and k.lower() != "content-encoding":
                h.send_header(k, v)
        h.send_header("connection", "close")
        h.end_headers()
        buf, use, err = "", {}, None
        try:
            while True:
                chunk = resp.read1(65536) if callable(getattr(resp, "read1", None)) else resp.read(65536)
                if not chunk:
                    break
                h.wfile.write(chunk)
                h.wfile.flush()
                buf += chunk.decode("utf-8", "replace")
                evs, buf = sse_events(buf)
                for ev in evs:
                    if ev.get("type") == "message_start":
                        msg = ev.get("message") or {}
                        rec["model"] = msg.get("model") or rec["model"]
                        merge_usage(use, msg.get("usage"))
                    elif ev.get("type") == "message_delta":
                        merge_usage(use, ev.get("usage"))
                    elif ev.get("type") == "error":
                        err = ev.get("error")
                    if rec["kind"] != "count" and use:
                        with self.lock:
                            rec["usage"] = dict(use)
                            rec["cost_usd"] = round(usage_cost(rec["model"], use), 6)
        except OSError as e:
            err = err or str(e)[:300]
        if rec["kind"] == "count" or not use:
            try:
                tail = json.loads(buf) if buf.strip().startswith("{") else None
            except ValueError:
                tail = None
            if tail and rec["kind"] == "count":
                rec["usage"] = {"input_tokens": tail.get("input_tokens")}
            elif tail and tail.get("usage"):
                rec["usage"] = tail["usage"]
                rec["cost_usd"] = round(usage_cost(rec["model"], tail["usage"]), 6)
            elif tail and tail.get("error"):
                err = tail["error"]
        if err:
            rec["error"] = err
        rec["end_ms"] = now_ms()
        self._write(rec)

    def _write(self, rec):
        with self.lock:
            self.log.write(json.dumps(rec) + "\n")
            self.log.flush()

    def close(self):
        try:
            self.server.shutdown()
            self.server.server_close()
        except OSError:
            pass
        self.log.close()


# The run -------------------------------------------------------------------

def free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def src_commit(src):
    r = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def marked_pids(mark):
    """This user's processes whose environment holds the run's mark (every
    process the terminal's jobs started inherits it)."""
    r = subprocess.run(["ps", "-wwE", "-U", str(os.getuid()), "-o", "pid=,command="], capture_output=True, text=True)
    out = []
    for line in r.stdout.splitlines():
        pid, _, rest = line.strip().partition(" ")
        if mark in rest and pid.isdigit() and int(pid) != os.getpid():
            out.append(int(pid))
    return sorted(out)


def run_unii(opts):
    task = team_eval.load_task(opts.tasks, opts.task)
    out = os.path.abspath(opts.out)
    traces = os.path.join(out, "traces")
    os.makedirs(traces, exist_ok=True)
    brain = tempfile.mkdtemp(prefix="te.", dir="/tmp")
    repo_dir = os.path.abspath(opts.keep_repo) if opts.keep_repo else os.path.join(brain, "repo")
    stubs_log = os.path.join(out, "stubs.jsonl")
    shims = os.path.join(brain, "shims")
    team_eval.write_stubs(shims, stubs_log)
    extra = dict(kv.split("=", 1) for kv in opts.env)
    mark = f"TEAM_EVAL_UNII_RUN={os.path.basename(brain)}"
    info = {"task": task["id"], "arm": "C", "env": opts.env, "budget_usd": opts.budget_usd, "flags": [], "pid": os.getpid(),
            "cost_method": ("tokens x list prices (unii_bench.PRICES) from the usage each Messages API response reported "
                            "(message_start + message_delta, as UniiChat's Anthropic.ts reads it), recorded by a proxy "
                            "between UniiChat and ANTHROPIC_BASE_URL; cache writes split 5m/1h when the API says, else "
                            "5m (UniiChat's mark); web searches $0.01 each; count_tokens calls are free")}

    def log(msg):
        print(f"[team-eval {time.strftime('%H:%M:%S')}] {msg}", flush=True)

    procs = {}
    proxy = None
    port = free_port()
    site = f"http://127.0.0.1:{port}"
    unii_dir = os.path.join(brain, "unii")
    term_home = os.path.join(brain, "term")
    work = os.path.join(brain, "work")
    token = os.urandom(32).hex()
    observed = []  # (ms, server event)
    obs_lock = threading.Lock()
    disk_seen = {}  # main/ page index -> ms first seen on disk
    sent = {}

    def read_main():
        recs = []
        for f in sorted(glob.glob(os.path.join(unii_dir, "users", "*", "main", "*.jsonl"))):
            for line in open(f, errors="replace"):
                try:
                    recs.append(json.loads(line))
                except ValueError:
                    pass
        t = now_ms()
        for r in recs:
            if "i" in r:
                disk_seen.setdefault(r["i"], t)
        return recs

    def seen_at():
        with obs_lock:
            ev = list(observed)
        first = {}
        for at, m in ev:
            if m.get("$") == "entry" and m.get("agent") is None and isinstance(m.get("id"), int):
                first.setdefault(m["id"], at)
        return {i: min(t, first.get(i, t)) for i, t in disk_seen.items()} | {i: t for i, t in first.items() if i not in disk_seen}

    def states():
        with obs_lock:
            return [m for _, m in observed if m.get("$") == "state"]

    def start(name, args, env, cwd, stdin=None):
        p = subprocess.Popen(args, cwd=cwd, env=env, stdin=stdin if stdin is not None else subprocess.DEVNULL,
                             stdout=open(os.path.join(traces, f"{name}.log"), "w"), stderr=subprocess.STDOUT,
                             start_new_session=True)
        procs[name] = p
        return p

    def http(path, data=None, headers=None, form=False):
        h = dict(headers or {})
        if data is not None and not form and not isinstance(data, bytes):
            data, h["content-type"] = json.dumps(data).encode(), "application/json"
        elif form:
            data, h["content-type"] = urllib.parse.urlencode(data).encode(), "application/x-www-form-urlencoded"

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None

        req = urllib.request.Request(site + path, data=data, headers=h, method="POST" if data is not None else "GET")
        try:
            r = urllib.request.build_opener(NoRedirect).open(req, timeout=30)
            return r.status, r.read().decode(errors="replace"), dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(errors="replace"), dict(e.headers)

    def send(pid, text):
        key = f"te-{pid}-{now_ms()}"
        q = urllib.parse.urlencode({"$": "say", "id": key, "sizes": ""})
        status, body, _ = http("/api/act?" + q, text.encode(), {"authorization": "Bearer " + token,
                                                                 "content-type": "application/octet-stream"})
        if status != 200:
            raise RuntimeError(f"say {pid}: HTTP {status} {body[:300]}")
        with obs_lock:
            observed.append((now_ms(), {"$": "eval.sent", "key": key, "id": pid, "text": text}))
        return key

    def stop_all():
        # The terminal first: its own quit kills its jobs' process groups (Machine.end).
        order = [n for n in ("term", "observer", "server") if n in procs]
        for n in order:
            p = procs[n]
            if p.poll() is None:
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        left = []
        for step in ("term", "kill", "check"):
            left = sorted(set(marked_pids(mark)) | {p.pid for p in procs.values() if p.poll() is None})
            if not left or step == "check":
                break
            for pid in left:
                try:
                    os.kill(pid, signal.SIGTERM if step == "term" else signal.SIGKILL)
                except ProcessLookupError:
                    pass
            time.sleep(3)
        for p in procs.values():
            for fd in (p.stdin,):
                try:
                    fd and fd.close()
                except OSError:
                    pass
        info["acpmux_left"] = left
        log(f"acpmux cleanup: {'no process holds its locks' if not left else 'STILL HELD by ' + str(left)}"
            " (arm C runs no acpmux; these are its UniiChat server, terminal, observer and their jobs)")

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))
    base_commit = None
    try:
        src = os.path.abspath(os.environ.get("TEAM_EVAL_UNII_SRC") or extra.get("UNII_SRC") or UNII_SRC_DEFAULT)
        commit = src_commit(src)
        info["unii_commit"] = commit
        if not commit.startswith(UNII_COMMIT):
            raise SystemExit(f"arm C: {src} is at {commit or 'no git commit'}, not UniiChat {UNII_COMMIT}")
        base_url = extra.get("ANTHROPIC_BASE_URL")
        if not base_url:
            raise SystemExit("arm C: --env ANTHROPIC_BASE_URL=... is required (the route UniiChat's calls go to)")
        pick = unii_pick(extra.get("OPTCHAT_CHIEF_MODEL"), extra.get("OPTCHAT_CHIEF_EFFORT"))
        agents_pick = unii_pick(extra.get("OPTCHAT_SUBAGENT_MODEL") or extra.get("OPTCHAT_CHIEF_MODEL"),
                                extra.get("OPTCHAT_SUBAGENT_EFFORT") or extra.get("OPTCHAT_CHIEF_EFFORT"))
        info["unii_pick"] = pick
        info["unii_agents_pick"] = agents_pick
        base_commit = team_eval.checkout(opts.repo, task["base"], repo_dir)
        info["repo"] = repo_dir
        custom = {}
        for line in (extra.get("ANTHROPIC_CUSTOM_HEADERS") or "").splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                custom[k.strip()] = v.strip()
        proxy = Proxy(base_url, os.path.join(traces, "api.jsonl"), custom)
        # The copy, patched; the clone stays as cloned.
        copy = os.path.join(brain, "src")
        shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", "ios"))
        patched = patch_source(copy, proxy.url)
        if patched < 2:
            raise SystemExit(f"arm C: Anthropic.ts held {patched} copies of {ANTHROPIC}, expected 2 (messages, count_tokens)")
        info["unii_patch"] = f"Anthropic.ts: {ANTHROPIC} -> the recording proxy ({patched} URLs)"
        path = f"{shims}:{os.environ['HOME']}/.local/bin:{os.environ['HOME']}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        bun = shutil.which("bun", path=path)
        if not bun:
            raise SystemExit("arm C: no bun on PATH")
        info["bun"] = subprocess.run([bun, "--version"], capture_output=True, text=True).stdout.strip()
        base_env = {"HOME": os.environ["HOME"], "LANG": "en_US.UTF-8", "USER": os.environ.get("USER", "cmux"), "PATH": path}
        server_env = dict(base_env, UNII_DIR=unii_dir, UNII_SITE=site, UNII_PICK=pick, UNII_AGENTS=agents_pick,
                          ANTHROPIC_API_KEY=extra.get("ANTHROPIC_API_KEY") or "sk-ant-placeholder-the-route-signs",
                          UNII_NO_TELEMETRY="1")
        os.makedirs(unii_dir)
        server = start("server", [bun, os.path.join(copy, "Server.ts"), str(port)], server_env, copy)
        for _ in range(300):
            if server.poll() is not None:
                raise SystemExit("arm C: the UniiChat server exited; see traces/server.log")
            if _port_open(port) and http("/api/hello")[0] == 200:
                break
            time.sleep(0.1)
        else:
            raise SystemExit("arm C: the UniiChat server never answered /api/hello")
        # Sign-in, as Term.ts login_run does, the link read from the server's log.
        status, body, _ = http("/api/login", {"who": WHO, "key": token})
        code = json.loads(body).get("code") if status == 200 else None
        if not code:
            raise SystemExit(f"arm C: /api/login gave {status} {body[:300]}")
        link = None
        for _ in range(100):
            m = re.findall(r"/auth\?t=([A-Za-z0-9_-]+)", open(os.path.join(traces, "server.log")).read())
            if m:
                link = m[-1]
                break
            time.sleep(0.1)
        if not link:
            raise SystemExit("arm C: the server printed no sign-in link")
        status, _, hdrs = http("/auth", {"t": link, "code": code}, form=True)
        if status != 302 or "terminal=1" not in hdrs.get("Location", hdrs.get("location", "")):
            raise SystemExit(f"arm C: /auth confirm gave {status} {hdrs}")
        if http("/api/me", headers={"authorization": "Bearer " + token})[0] != 200:
            raise SystemExit("arm C: signed in, but /api/me refuses the token")
        host = f"127.0.0.1:{port}"
        os.makedirs(os.path.join(term_home, host), mode=0o700)
        fd = os.open(os.path.join(term_home, host, "token"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, token.encode())
        os.close(fd)
        info["sign_in"] = "POST /api/login {who, key} -> code; /auth?t= from the server log; POST /auth {t, code}"
        # The agent's dir on this device (WORK/main) is the task repo.
        os.makedirs(work)
        os.symlink(repo_dir, os.path.join(work, "main"))
        mk, mv = mark.split("=", 1)
        term_env = dict(base_env, UNII_HOME=term_home, UNII_WORK=work, UNII_NO_TELEMETRY="1", SHELL="/bin/bash",
                        TERM="dumb", **{mk: mv})
        obs_js = os.path.join(brain, "observer.js")
        open(obs_js, "w").write(OBSERVER_JS)
        obs = start("observer", [bun, obs_js, site, token], dict(base_env, **{mk: mv}), brain)
        obs_path = os.path.join(traces, "observer.log")
        obs_pos = [0]

        def read_observer():
            with open(obs_path, errors="replace") as f:
                f.seek(obs_pos[0])
                chunk = f.read()
            if not chunk:
                return
            cut = chunk.rfind("\n") + 1
            obs_pos[0] += len(chunk[:cut].encode())
            with obs_lock:
                for line in chunk[:cut].splitlines():
                    try:
                        e = json.loads(line)
                        observed.append((e["at"], e["msg"]))
                    except (ValueError, KeyError):
                        pass

        # The terminal reads its input from a pipe kept open (closed, it quits once idle).
        term = start("term", [bun, os.path.join(copy, "Term.ts"), site], term_env, repo_dir, stdin=subprocess.PIPE)
        for _ in range(300):
            read_observer()
            if term.poll() is not None:
                raise SystemExit("arm C: the unii terminal exited; see traces/term.log")
            if os.path.getsize(os.path.join(traces, "term.log")) > 0 and states():
                break
            time.sleep(0.1)
        else:
            raise SystemExit("arm C: the unii terminal never showed the chat")
        time.sleep(1)
        before = max([r["i"] for r in read_main() if "i" in r] or [-1])
        info["unii_hello_lines"] = before + 1

        t0 = now_ms()
        sent["brief"] = t0
        send("brief", task["brief"].replace("{repo}", repo_dir))
        log(f"up: task {task['id']} arm C ({pick}) repo {repo_dir} server {site}")
        pending = sorted(task["followups"], key=lambda f: f["at"])
        deadline = t0 + opts.max_minutes * 60000
        last_activity, seen = now_ms(), -1
        end = "deadline"
        while now_ms() < deadline:
            read_observer()
            recs = read_main()
            for name, p in procs.items():
                if p.poll() is not None:
                    end = f"{name} exited {p.returncode}"
                    break
            else:
                name = None
            if name:
                info["flags"].append(f"the UniiChat {end}")
                break
            if pending and now_ms() >= t0 + pending[0]["at"] * 1000:
                f = pending.pop(0)
                sent[f["id"]] = now_ms()
                send(f["id"], f["text"])
                log(f"sent {f['id']}")
                last_activity = now_ms()
            api = proxy.snapshot()
            with obs_lock:
                n_obs = len(observed)
            activity = n_obs + len(recs) + len(api) + sum(1 for r in api if r.get("end_ms"))
            if activity != seen:
                seen, last_activity = activity, now_ms()
            spent = proxy.spent()
            if spent > opts.budget_usd:
                end = "budget"
                info["flags"].append(f"stopped at ${spent:.2f}, over the ${opts.budget_usd:.0f} budget")
                break
            if not pending:
                st = states()
                last = st[-1] if st else {}
                running = bool(last.get("busy")) or bool(last.get("agents")) or any(not r.get("end_ms") for r in api)
                if not running and now_ms() - last_activity > opts.quiet_seconds * 1000:
                    end = "idle"
                    break
            time.sleep(0.5)
        info["end"] = end
        info["minutes"] = round((now_ms() - t0) / 60000, 1)
    except BaseException as e:
        info.setdefault("end", f"error: {e!r}"[:300])
        if sent.get("brief"):
            info.setdefault("minutes", round((now_ms() - sent["brief"]) / 60000, 1))
        raise
    finally:
        try:
            stop_all()
        except Exception as e:  # cleanup must still write the evidence
            info["flags"].append(f"cleanup failed: {e}")
            print(f"[team-eval] acpmux cleanup: STILL HELD by [unknown: {e}]", flush=True)
        try:
            _evidence(info, out, traces, unii_dir, task, repo_dir, base_commit, stubs_log, observed, proxy,
                      read_main if os.path.isdir(unii_dir) else (lambda: []), seen_at, sent, log)
        except Exception as e:
            info["flags"].append(f"evidence failed: {e}")
        if proxy:
            proxy.close()
        json.dump(info, open(os.path.join(out, "run.json"), "w"), indent=1)
        shutil.rmtree(brain, ignore_errors=True)


def _port_open(port):
    import socket
    with socket.socket() as s:
        s.settimeout(0.2)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _evidence(info, out, traces, unii_dir, task, repo_dir, base_commit, stubs_log, observed, proxy, read_main, seen_at,
              sent, log):
    recs = read_main()
    after = info.get("unii_hello_lines", 0) - 1
    msgs, arrivals = unii_messages(recs, seen_at(), after)
    json.dump({"messages": msgs, "arrivals": arrivals}, open(os.path.join(out, "conversation.json"), "w"), indent=1)
    # The chat's own files (messages, tree, agents' logs, view), the server's events.
    for d in glob.glob(os.path.join(unii_dir, "users", "*")):
        shutil.copytree(d, os.path.join(traces, "unii-user-" + os.path.basename(d)), dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("up"))
    with open(os.path.join(traces, "observed.jsonl"), "w") as f:
        for at, m in list(observed):
            f.write(json.dumps({"at": at, **m}) + "\n")
    diff = team_eval.final_diff(repo_dir, base_commit) if base_commit else ""
    open(os.path.join(out, "diff.patch"), "w").write(diff)
    stub_calls = [l for l in open(stubs_log)] if os.path.exists(stubs_log) else []
    api = proxy.snapshot() if proxy else []
    agent_lines = []
    for f in glob.glob(os.path.join(unii_dir, "users", "*", "**", "*.jsonl"), recursive=True):
        if "/agent/" in f:
            for line in open(f, errors="replace"):
                try:
                    agent_lines.append((os.path.basename(f)[:-6], json.loads(line)))
                except ValueError:
                    pass
    texts = [("message", team_eval.text_of(m)) for m in msgs] + [("diff", diff)] + [("stub", l) for l in stub_calls]
    texts += [("tool", r.get("text", "")) for r in join_pages(recs) if r["i"] > after and r["kind"] in ("tool", "work", "echo")]
    texts += [("agent " + name, r.get("text", "")) for name, r in agent_lines if r.get("kind") in ("tool", "unii", "work", "echo")]
    states = [m for _, m in observed if m.get("$") == "state"]
    agents = set(n for s in states for n in s.get("agents") or []) | {n for n, _ in agent_lines}
    flags = {f for r in api for f in [price_of(r.get("model"))[1]] if f}
    if flags:
        info["flags"] += sorted(flags)
    by_kind = {}
    for r in api:
        k = by_kind.setdefault(r.get("kind"), {"requests": 0, "errors": 0, "input": 0, "cache_read": 0, "cache_write": 0, "output": 0})
        k["requests"] += 1
        k["errors"] += 1 if r.get("error") or (r.get("status") or 200) >= 400 else 0
        u = r.get("usage") or {}
        k["input"] += u.get("input_tokens") or 0
        k["cache_read"] += u.get("cache_read_input_tokens") or 0
        k["cache_write"] += u.get("cache_creation_input_tokens") or 0
        k["output"] += u.get("output_tokens") or 0
    info.update({
        "sent": sent,
        "timeline": team_eval.timeline(sent, msgs, arrivals),
        "cost_usd": cost_split(api),
        "api": by_kind,
        "turns": turns_of(states),
        "spawns": len(agents),
        "agents": sorted(agents),
        "receipts": 0,
        "reports": sum(1 for r in join_pages(recs) if r["i"] > after and r["kind"] == "work"),
        "chief_messages": sum(1 for m in msgs if m.get("author") == CHIEF),
        "diff_lines": diff.count("\n"),
        "stub_calls": len(stub_calls),
        "leaks": team_eval.leak_hits(texts, task),
    })
    if info["leaks"]:
        info["flags"].append("the reference answer was mentioned")
    log(f"done: {info.get('end')} after {info.get('minutes')} min, ${info['cost_usd']['all']}, {info['turns']} turns, "
        f"{info['spawns']} agents, diff {info['diff_lines']} lines, flags {info['flags']}")
