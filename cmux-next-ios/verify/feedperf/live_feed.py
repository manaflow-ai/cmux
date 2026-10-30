#!/usr/bin/env python3
"""The Feed under real use: two rig Macs, real agents, the phone scrolling.

Runs ON a cmux mini with `axe` and a simulator (verify/multimac's phone host).
Two hidden rig Macs (verify/multimac/rig.py, ~/multimac-rig on each mini) are
signed in to the dev account; the phone (a Demo build, any bundle id) signs in
as the dev user, so both Macs feed it. Then:

- on the first rig, real agents work: a Codex session and a Claude session
  (acpmux harnesses `codex` and `claude-sr2`), each given a few prompts that
  make them read, run commands and answer with code;
- on the second rig, the fake agent asks permissions (as Codex or Claude
  Code would), one every few seconds;
- the phone relaunches on the Feed with the frame log on and scrolls it top
  to bottom and back (`CMUX_MOBILE_FEED_AUTOSCROLL`) while the events arrive,
  optionally with `--seed N` synthetic events merged under the real ones.

    python3 live_feed.py --app PATH --udid UDID --agents-rig HOST|local|none --asks-rig HOST|local|none
                         [--seed 0] [--passes 2] [--label NAME] [--skip-sign-in] [--out DIR]

The minis do not reach each other over SSH, so a rig on another mini is
driven from the laptop instead (`live_feed_agents.sh HOST`) and this side
gets `--agents-rig none`.

Writes DIR/NAME.jsonl (the frame log), DIR/NAME.json (what the Feed held, the
agents' sessions) and screenshots.
"""
import argparse
import json
import os
import plistlib
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
import journey  # noqa: E402
from journey import Journey  # noqa: E402
from sim import Sim  # noqa: E402

PROMPTS = {
    "codex": [
        "List the files in this folder, then write a short Python script that counts words in a file, and show it in a code block.",
        "Run `uname -a` and `sw_vers`, then summarize the machine in a markdown table.",
        "Explain the difference between a merge and a rebase in git, with a small example of each in code blocks.",
    ],
    "claude-sr2": [
        "Write a Swift function that parses ISO 8601 dates, with a short explanation and a usage example.",
        "Run `ls -la` and `df -h`, then tell me in a markdown table which volume has the most free space.",
        "Draft a three-step plan to profile a SwiftUI list that hitches, with a code block for the Instruments command.",
    ],
}


def ssh(host, cmd, timeout=120):
    return subprocess.run(["ssh", "-o", "ConnectTimeout=10", host, cmd], capture_output=True, text=True, timeout=timeout)


def rig(host, *args, timeout=120):
    """rig.py on `host`; `local` is this mini's own rig (the minis do not SSH to each other)."""
    if host == "local":
        return subprocess.run(["python3", "rig.py", *args], cwd=os.path.expanduser("~/multimac-rig"),
                              capture_output=True, text=True, timeout=timeout)
    quoted = " ".join("'" + a.replace("'", "'\\''") + "'" for a in args)
    return ssh(host, f"cd ~/multimac-rig && python3 rig.py {quoted}", timeout=timeout)


def real_agents(host, log, stop):
    """Real Codex and Claude sessions on `host`, prompted one after another until `stop`."""
    def run(harness):
        name = f"feedperf-{harness}-{int(time.time())}"
        first = True
        for prompt in PROMPTS[harness] * 3:
            if stop.is_set():
                return
            if first:
                r = rig(host, "acpmux", "new", "-m", harness, "-n", name, "--cwd", "/Users/cmux/multimac-rig/work", prompt, timeout=600)
                first = False
            else:
                r = rig(host, "acpmux", "send", name, prompt, timeout=600)
            log(f"{host} {harness}: rc={r.returncode} {r.stdout.strip()[-160:]!r} {r.stderr.strip()[-160:]!r}")
            if r.returncode != 0 and first is False and "not found" in r.stderr:
                return
    threads = [threading.Thread(target=run, args=(h,), daemon=True) for h in PROMPTS]
    for t in threads:
        t.start()
    return threads


def fake_asks(host, log, stop, every=6.0):
    """The fake agent asks a permission every few seconds (as Codex or Claude Code would)."""
    commands = ["git push origin main", "rm -rf build/", "npm publish", "cargo clippy --fix", "docker compose up -d",
                "swift test --parallel", "./scripts/reload.sh --tag feed", "kubectl rollout restart deploy/web"]
    i = 0
    while not stop.is_set():
        r = rig(host, "ask", f"ask: {commands[i % len(commands)]} (#{i})")
        log(f"{host} ask #{i}: {r.stdout.strip()!r}")
        i += 1
        stop.wait(every)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--agents-rig", required=True)
    ap.add_argument("--asks-rig", required=True)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--passes", type=int, default=2)
    ap.add_argument("--warmup", type=float, default=90, help="seconds of agent work before the scroll")
    ap.add_argument("--label", default="live")
    ap.add_argument("--skip-sign-in", action="store_true")
    ap.add_argument("--choose", action="append", default=[],
                    help="a Mac (its name) to link first from the Workspaces filter, as multimac_feed.py does")
    ap.add_argument("--out", default=os.path.join(HERE, "evidence"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, f"{a.label}.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    with open(os.path.join(a.app, "Info.plist"), "rb") as f:
        bundle = plistlib.load(f)["CFBundleIdentifier"]
    journey.BUNDLE = bundle
    sim = Sim(a.udid, shots_dir=os.path.join(a.out, f"{a.label}-shots"))
    j = Journey(sim, None, a.out, a.app, log)

    rigs = [h for h in (a.agents_rig, a.asks_rig) if h != "none"]
    for host in rigs:
        r = rig(host, "launch", timeout=300)
        log(f"rig {host} launch: {r.stdout.strip()} {r.stderr.strip()[-200:]}")
    if not a.skip_sign_in:
        j.s_fresh_install()
        j.s_sign_in()
        j.s_choose_space()
        log("signed in")
    else:
        subprocess.run(["xcrun", "simctl", "install", a.udid, a.app], check=True, capture_output=True)

    stop = threading.Event()
    if a.agents_rig != "none":
        real_agents(a.agents_rig, log, stop)
    if a.asks_rig != "none":
        threading.Thread(target=fake_asks, args=(a.asks_rig, log, stop), daemon=True).start()
    # Link each rig Mac (the Workspaces filter), then show All Macs; then the Feed while the agents work.
    sim.launch(bundle)
    time.sleep(4)
    for name in a.choose:
        j.back_to_list()
        sim.tap_q(ident="workspaces.filter", timeout=60)
        time.sleep(1.0)
        sim.tap_q(contains=name, timeout=20)
        time.sleep(3.0)
        # A Mac the phone has not linked yet lists as "· Not connected, Connect": connect it.
        connect = [e for e in sim.find(kind="Button") if name in e.label and "Connect" in e.label]
        if connect:
            sim.tap_el(connect[-1])
            time.sleep(10.0)
        log(f"linked {name}")
    if a.choose:
        sim.tap_q(ident="workspaces.filter", timeout=20)
        time.sleep(1.0)
        sim.tap_q(label="All Macs", timeout=20)
        time.sleep(2.0)
    j.tab("Feed")
    log(f"agents working for {a.warmup:.0f} s")
    time.sleep(a.warmup)
    sim.shot(f"{a.label}-before")

    # Relaunch with the frame log and the autoscroll; live events keep arriving.
    container = subprocess.run(["xcrun", "simctl", "get_app_container", a.udid, bundle, "data"], capture_output=True, text=True).stdout.strip()
    framelog = os.path.join(container, "Library/Caches/framelog.jsonl")
    if os.path.exists(framelog):
        os.remove(framelog)
    env = {"CMUX_MOBILE_FRAMELOG": "1", "CMUX_MOBILE_FEED_AUTOSCROLL": str(a.passes), "CMUX_MOBILE_FEED_SETTLE": "8",
           "CMUX_MOBILE_FEED_IDLE_WINDOW": "5", "CMUX_MOBILE_FEED_EXIT_WHEN_DONE": "1"}
    if a.seed:
        env["CMUX_MOBILE_FEED_STRESS"] = str(a.seed)
    sim.launch(bundle, args=["-cmux-mobile-tab", "feed"], env=env)
    shot_at = time.time() + 14
    deadline = time.time() + 600
    shot = False
    while time.time() < deadline:
        running = subprocess.run(["xcrun", "simctl", "spawn", a.udid, "launchctl", "list"], capture_output=True, text=True).stdout
        if not shot and time.time() > shot_at:
            sim.shot(f"{a.label}-scrolling")
            shot = True
        if bundle not in running:
            break
        time.sleep(2)
    stop.set()
    lines = open(framelog).read() if os.path.exists(framelog) else ""
    with open(os.path.join(a.out, f"{a.label}.jsonl"), "w") as f:
        f.write(lines)
    sessions = {h: rig(h, "acpmux", "ls").stdout for h in rigs}
    pending = {h: rig(h, "acpmux", "pending").stdout for h in rigs}
    with open(os.path.join(a.out, f"{a.label}.json"), "w") as f:
        json.dump({"bundle": bundle, "rigs": rigs, "seed": a.seed, "sessions": sessions, "pending": pending}, f, indent=2)
    log(f"frame log: {len(lines.splitlines())} windows; sessions: {sessions}")
    subprocess.run([sys.executable, os.path.join(HERE, "summarize.py"), os.path.join(a.out, f"{a.label}.jsonl")])


if __name__ == "__main__":
    main()
