#!/usr/bin/env python3
"""Chief while its model server is down, on the e2e rig.

Real tagged cmux-next Mac app + the iOS app in one headless simulator, over
the real link (the rig's own setup: e2e.py). The Mac's Chief is pointed at a
closed port through its normal config: its Claude Code session settings
(`<Chief home>/optchat/session/.claude/settings{,.local}.json`, `env`
`ANTHROPIC_BASE_URL`), with `CLAUDE_CODE_MAX_RETRIES=0` so the failure comes
in seconds rather than after Claude Code's own retries. Then the real server
"comes back" (the files are restored) and the phone's Try Again is used.

  python3 chief_down.py --mac-app PATH [--no-build] [--keep]

Videos: <out>/before-model-down.mp4 (the error state) and
<out>/after-model-back.mp4 (the recovery), plus shots/ and results.json.
Sends two short Chief messages (paid model calls; the second only after the
server is back). Never touches the user's ~/.claude/settings.json.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import e2e  # noqa: E402
from e2e import CNX, RUNTIMES, build_ios, ensure_sim, sh  # noqa: E402
from journey import Journey  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402

CLOSED = "http://127.0.0.1:9"
LEAKS = re.compile(r"\d{1,3}(\.\d{1,3}){3}|:31415|inference|API Error|turn failed", re.I)


def session_settings(mac):
    base = os.path.expanduser(f"~/.cmux/chief/{mac.bundle_id}/optchat/session/.claude")
    return [os.path.join(base, n) for n in ("settings.json", "settings.local.json")]


def point_chief_at(files, url, backup_dir):
    """Sets env.ANTHROPIC_BASE_URL (and no client retries) in Chief's session settings."""
    for f in files:
        keep = os.path.join(backup_dir, os.path.basename(f))
        if not os.path.exists(keep):
            shutil.copy2(f, keep)
        doc = json.load(open(f))
        doc.setdefault("env", {})["ANTHROPIC_BASE_URL"] = url
        doc["env"]["CLAUDE_CODE_MAX_RETRIES"] = "0"
        json.dump(doc, open(f, "w"), indent=2)


def restore(files, backup_dir):
    for f in files:
        keep = os.path.join(backup_dir, os.path.basename(f))
        if os.path.exists(keep):
            shutil.copy2(keep, f)


def visible_texts(sim):
    return [str(e.label) for e in sim.tree() if e.label]


def wait_text(sim, pattern, timeout, interval=1.0):
    t = time.time()
    while time.time() - t < timeout:
        for text in visible_texts(sim):
            if re.search(pattern, text):
                return text, time.time() - t
        time.sleep(interval)
    return None, time.time() - t


def send_to_chief(sim, text):
    sim.tap_q(ident="conversation.composer.text")
    time.sleep(0.6)
    sim.softtype(text)
    sim.tap_q(ident="conversation.composer.send")


def open_settings_shot(sim, name):
    # The header's name opens Chief's info (the trailing button is Invite to cmux).
    sim.tap_q(ident="conversation.header.name")
    sim.wait(timeout=10, ident="chief.settings")
    time.sleep(2.5)
    path = sim.shot(name)
    texts = visible_texts(sim)
    # Chief's info is pushed (Back); older builds showed a sheet (Done).
    done = sim.wait(timeout=10, label="Back", kind="Button") or sim.wait(timeout=2, ident="chief.settings.done")
    if done is None:
        raise LookupError("no Back (or Done) on Chief's info")
    sim.tap_el(done)
    time.sleep(1.0)
    return path, texts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--sim-name", default="cmux-mobile-chiefdown-ios26")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--fail-timeout", type=float, default=420)
    a = ap.parse_args()

    mac_app = os.path.abspath(a.mac_app)
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    stamp = datetime.datetime.now().strftime("%Y-%m-%d")
    out = os.path.join(CNX, "verify/evidence", stamp, "chief-model-down", datetime.datetime.now().strftime("%H%M%S"))
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    app_path = os.path.join(CNX, "build/dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app") if a.no_build else build_ios(log, "Demo")
    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app).prepare()
    mac.seed_pairing(names=[a.sim_name])
    udid = ensure_sim(a.sim_name, RUNTIMES[a.ios], log)
    sim = Sim(udid, os.path.join(out, "shots"))
    result = {"ios_head": sh("git", "-C", CNX, "rev-parse", "HEAD").stdout.strip(), "mac_app": os.path.basename(mac_app),
              "simulator": a.sim_name, "checks": {}}
    files, backup = [], os.path.join(out, "settings-backup")
    os.makedirs(backup, exist_ok=True)
    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}), cmux-mobile-host {'running' if mac.wait_hostd(120) else 'NOT running'}")
        j = Journey(sim, mac, out, app_path, log)
        steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        log(f"setup: {[(s['id'], s['status']) for s in steps]}")

        # Chief's brain is up once its session settings exist.
        files = session_settings(mac)
        t = time.time()
        while not all(os.path.exists(f) for f in files) and time.time() - t < 120:
            time.sleep(1)
        point_chief_at(files, CLOSED, backup)
        log(f"Chief pointed at {CLOSED} (closed port) in {files}")

        # ---- before: the model server is down ---------------------------------
        j.back_to_list(); j.tab("Home")
        sim.tap_q(ident="home.chief")
        sim.wait(timeout=30, ident="conversation.transcript")
        time.sleep(2)
        sim.record_start(os.path.join(out, "before-model-down.mp4"))
        send_to_chief(sim, "Reply with just the word ok.")
        failed, waited = wait_text(sim, r"couldn.t reach its model|model was too busy|ran into a problem|^(ok|Ok|OK)\.?$",
                                   a.fail_timeout)
        log(f"Chief's answer after {waited:.0f} s: {failed!r}")
        if failed and re.match(r"^(ok|Ok|OK)\.?$", failed):
            raise SystemExit("Chief answered: the session settings edit did not reach its running Claude Code; "
                             "restart Chief's brain with the closed port instead")
        time.sleep(2)
        sim.shot("before-conversation")
        leaks = [t for t in visible_texts(sim) if LEAKS.search(t)]
        bar = sim.find(ident="chief.failure.bar")
        settings_shot, settings_texts = open_settings_shot(sim, "before-settings")
        sim.record_stop()
        result["checks"]["before"] = {
            "failure_text": failed, "seconds": round(waited, 1), "leaks": leaks, "try_again_bar": bool(bar),
            "settings": [t for t in settings_texts if re.search(r"model|Model|Opus|Sonnet|Default|reach|Chief", t)][:12],
        }

        # ---- after: the model server is back ----------------------------------
        restore(files, backup)
        log("Chief's session settings restored (the real model server)")
        sim.record_start(os.path.join(out, "after-model-back.mp4"))
        time.sleep(1.5)
        sim.tap_q(ident="chief.failure.bar")
        ok, waited = wait_text(sim, r"^(ok|Ok|OK)\.?$", 240)
        log(f"Chief answered after Try Again in {waited:.0f} s: {ok!r}")
        time.sleep(2)
        sim.shot("after-conversation")
        after_shot, after_texts = open_settings_shot(sim, "after-settings")
        sim.record_stop()
        result["checks"]["after"] = {
            "reply": ok, "seconds": round(waited, 1), "bar_gone": not sim.find(ident="chief.failure.bar"),
            "model_status_gone": not any("isn't reachable" in t for t in after_texts),
            "settings": [t for t in after_texts if re.search(r"model|Model|Opus|Sonnet|Default|reach|Chief", t)][:12],
        }
    finally:
        sim.record_stop()
        if files:
            restore(files, backup)
        json.dump(result, open(os.path.join(out, "results.json"), "w"), indent=2, default=str)
        log(f"results -> {os.path.join(out, 'results.json')}")
        if not a.keep:
            log(f"quitting the rig Mac app: {mac.quit()}")
            sh("xcrun", "simctl", "shutdown", udid)
            sh("xcrun", "simctl", "delete", udid)
            log(f"simulator {a.sim_name} deleted")


if __name__ == "__main__":
    main()
