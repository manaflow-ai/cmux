#!/usr/bin/env python3
"""Call Chief (live voice call) in the iOS app, end to end in one headless simulator.

Runs ON a cmux mini with the Debug simulator app (`xcrun simctl`, AXe taps on that
simulator only; Simulator.app is never opened). Mock sign-in (CMUX_MOBILE_MOCK_AUTH=1)
gives a signed-in shell with sample workspaces and the mock Chief, which answers
what the call sends it.

    python3 chief_call_live.py --app PATH/CmuxMobileApp.app [--out DIR] [--sim-name cmux-callchief]
                               [--phases nokey,real401,call,hold]

Phases:
  nokey    No OpenAI key: Call Chief in the Chief header opens Settings → Chief Calls;
           a made-up key typed there is checked with OpenAI for real (401) and not kept.
  real401  A made-up key seeded (DEBUG CMUX_MOBILE_CALL_SEED_KEY): Call Chief runs the
           real path (microphone, WebRTC offer, POST /v1/realtime/calls to OpenAI) and the
           call screen reports OpenAI's refusal; Open Settings, Check Key, Remove Key.
  call     The scripted call (DEBUG CMUX_MOBILE_CALL_DEMO=1): the Realtime API's own events
           through the real call session, tools and screen; list_workspaces reads the app's
           workspaces, send_to_chief really sends to Chief, Chief's reply comes back and is
           spoken, and the call hangs up with end_call. Started from Home's Chief row menu.
  hold     The scripted call kept open, started from Chief info's Call: minimize to the
           pill and back, type to Chief, Speaker and Mute, End.

Writes DIR/results.json, DIR/run.log, DIR/shots/*.png and DIR/*.mp4.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from sim import Sim, sh  # noqa: E402

BUNDLE = "dev.cmux.mobile"
DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
MADE_UP_KEY = "sk-proj-cmuxCallChiefVerifyNotARealKey0000"


class Run:
    def __init__(self, out):
        self.out = out
        os.makedirs(os.path.join(out, "shots"), exist_ok=True)
        self.log_file = open(os.path.join(out, "run.log"), "a")
        self.results = {"started": datetime.datetime.now().isoformat(timespec="seconds"), "checks": []}

    def log(self, msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        self.log_file.write(line + "\n")
        self.log_file.flush()

    def check(self, phase, name, ok, detail=""):
        self.results["checks"].append({"phase": phase, "name": name, "ok": bool(ok), "detail": detail})
        self.log(f"[{'PASS' if ok else 'FAIL'}] {phase}: {name} {detail}")

    def save(self):
        self.results["finished"] = datetime.datetime.now().isoformat(timespec="seconds")
        with open(os.path.join(self.out, "results.json"), "w") as f:
            json.dump(self.results, f, indent=2)


def ensure_sim(name, run):
    lst = json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))
    runtimes = json.loads(sh("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    ios = sorted((r for r in runtimes if r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS") and r["isAvailable"]),
                 key=lambda r: r["version"])
    runtime = ios[-1]["identifier"]
    udid = next((d["udid"] for devs in lst["devices"].values() for d in devs if d["name"] == name), None)
    if not udid:
        udid = sh("xcrun", "simctl", "create", name, DEVICE, runtime).strip()
        run.log(f"created simulator {name} {udid} ({runtime})")
    sh("xcrun", "simctl", "boot", udid, check=False)
    sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
    run.results["simulator"] = {"name": name, "udid": udid, "runtime": runtime}
    return udid


def fresh_app(sim, app, run):
    """Reinstall with no Keychain items and the microphone allowed (no system prompt)."""
    sh("xcrun", "simctl", "terminate", sim.udid, BUNDLE, check=False)
    sh("xcrun", "simctl", "uninstall", sim.udid, BUNDLE, check=False)
    sh("xcrun", "simctl", "keychain", sim.udid, "reset", check=False)
    sh("xcrun", "simctl", "install", sim.udid, app, timeout=300)
    sh("xcrun", "simctl", "privacy", sim.udid, "grant", "microphone", BUNDLE, check=False)
    run.log("installed fresh app, keychain reset, microphone granted")


def launch(sim, extra_env=None):
    env = {"CMUX_MOBILE_MOCK_AUTH": "1"}
    env.update(extra_env or {})
    sim.launch(BUNDLE, args=["-cmux-mobile-tab", "home"], env=env)
    time.sleep(3)


def open_chief(sim):
    """Home → the Chief conversation."""
    for ident in ("home.chief.mac", "home.chief"):
        e = sim.wait(timeout=8, ident=ident)
        if e:
            sim.tap_el(e)
            break
    return sim.wait(timeout=15, ident="chief.header.call") or sim.wait(timeout=5, ident="conversation.header.trailing")


def text_of(sim, ident):
    e = sim.wait(timeout=2, ident=ident)
    return (e.label or e.value or "") if e else ""


def wait_label(sim, ident, wanted, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        t = text_of(sim, ident)
        if any(w in t for w in wanted):
            return t
        time.sleep(0.4)
    return text_of(sim, ident)


def phase_nokey(sim, app, run):
    p = "nokey"
    fresh_app(sim, app, run)
    launch(sim)
    sim.shot("01-home")
    call = open_chief(sim)
    run.check(p, "Chief header has the Call Chief button", call is not None, repr(call))
    sim.shot("02-chief-conversation")
    if call:
        sim.tap_el(call)
    page = sim.wait(timeout=10, ident="settings.chiefCalls.keyField")
    run.check(p, "Call Chief without a key opens Settings → Chief Calls", page is not None)
    sim.shot("03-no-key-settings")
    if not page:
        return
    sim.tap_el(page)
    time.sleep(1)
    sim.softtype(MADE_UP_KEY)
    sim.shot("04-key-typed")
    sim.tap_q(ident="settings.chiefCalls.save")
    result = wait_label(sim, "settings.chiefCalls.checkResult", ["refused", "reach"], 25)
    run.check(p, "OpenAI checks the key for real and refuses a made-up one", "refused" in result, result)
    sim.shot("05-key-refused")
    run.check(p, "A refused key is not kept", sim.wait(timeout=2, ident="settings.chiefCalls.masked") is None)


def phase_real401(sim, app, run):
    p = "real401"
    fresh_app(sim, app, run)
    video = os.path.join(run.out, "real401.mp4")
    sim.record_start(video)
    launch(sim, {"CMUX_MOBILE_CALL_SEED_KEY": MADE_UP_KEY})
    call = open_chief(sim)
    if call:
        sim.tap_el(call)
    screen = sim.wait(timeout=10, ident="chief.call")
    run.check(p, "Call Chief with a key opens the call screen", screen is not None)
    sim.shot("10-real-connecting")
    failure = wait_label(sim, "chief.call.status", ["failed"], 40)
    detail = text_of(sim, "chief.call.failure")
    all_text = " ".join(sim.texts())
    run.check(p, "The real WebRTC call reaches OpenAI, which refuses the key (401)",
              "refused your API key" in all_text, f"status={failure!r} detail={detail!r}")
    sim.shot("11-real-refused")
    sim.tap_q(ident="chief.call.openSettings")
    masked = sim.wait(timeout=10, ident="settings.chiefCalls.masked")
    run.check(p, "Open Settings shows the stored key, masked", masked is not None and "0000" in (masked.label or masked.value or ""),
              repr(masked))
    sim.shot("12-settings-masked")
    sim.tap_q(ident="settings.chiefCalls.check")
    result = wait_label(sim, "settings.chiefCalls.checkResult", ["refused", "reach"], 25)
    run.check(p, "Check Key asks OpenAI again (refused)", "refused" in result, result)
    sim.shot("13-check-key")
    sim.tap_q(ident="settings.chiefCalls.remove")
    time.sleep(1)
    sim.shot("14-remove-confirm")
    sim.tap_q(label="Remove Key", kind="Button", timeout=8)
    field = sim.wait(timeout=8, ident="settings.chiefCalls.keyField")
    run.check(p, "Remove Key deletes it", field is not None)
    sim.shot("15-removed")
    sim.record_stop()


def phase_call(sim, app, run):
    p = "call"
    fresh_app(sim, app, run)
    launch(sim, {"CMUX_MOBILE_CALL_DEMO": "1"})
    video = os.path.join(run.out, "call.mp4")
    sim.record_start(video)
    row = sim.wait(timeout=10, ident="home.chief.mac") or sim.wait(timeout=5, ident="home.chief")
    run.check(p, "Home shows Chief", row is not None)
    if row:
        x, y = row.center
        sim.long_press(x, y, 1.2)
    item = sim.wait(timeout=8, label="Call Chief")
    run.check(p, "Chief's row menu has Call Chief", item is not None)
    sim.shot("20-home-menu")
    if item:
        sim.tap_el(item)
    run.check(p, "The call screen opens", sim.wait(timeout=10, ident="chief.call") is not None)
    sim.shot("21-connecting")
    seen = {}
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        texts = " ".join(sim.texts())
        status = text_of(sim, "chief.call.status")
        for key, needle in (("listening", "Listening"), ("speaking", "Speaking"), ("thinking", "Thinking"),
                            ("workspaces", "Checked workspaces"), ("sent", "Sent to Chief"),
                            ("queued", "Queued for Chief"), ("reply", "New message from Chief"),
                            ("spoke_reply", "Chief just replied"), ("ended", "Call ended")):
            if key not in seen and (needle in texts or needle in status):
                seen[key] = round(time.monotonic(), 1)
                sim.shot(f"22-{len(seen):02d}-{key}")
                run.log(f"saw {key}: status={status!r}")
        if "ended" in seen:
            break
        time.sleep(0.5)
    run.check(p, "User speech shows as Listening with live captions", "listening" in seen)
    run.check(p, "list_workspaces ran against the app's workspaces", "workspaces" in seen)
    run.check(p, "Chief's voice speaks (Speaking)", "speaking" in seen)
    run.check(p, "send_to_chief sent the task to Chief", "sent" in seen or "queued" in seen,
              "sent" if "sent" in seen else ("queued (Chief offline)" if "queued" in seen else ""))
    run.check(p, "Chief's reply came back into the call and was spoken", "reply" in seen and "spoke_reply" in seen)
    run.check(p, "end_call hung up after the goodbye", "ended" in seen)
    sim.shot("23-ended")
    done = sim.wait(timeout=5, ident="chief.call.done")
    if done:
        sim.tap_el(done)
    time.sleep(1.5)
    sim.record_stop()
    # The task the call sent is in the Chief conversation.
    open_chief(sim)
    time.sleep(2)
    convo = " ".join(sim.texts())
    run.check(p, "The Chief chat holds the message the call sent", "simulator tests" in convo)
    sim.shot("24-chief-chat-after-call")
    run.results["call_timeline"] = seen


def phase_hold(sim, app, run):
    p = "hold"
    fresh_app(sim, app, run)
    launch(sim, {"CMUX_MOBILE_CALL_DEMO": "hold"})
    video = os.path.join(run.out, "hold.mp4")
    sim.record_start(video)
    open_chief(sim)
    sim.tap_q(ident="conversation.header.name")
    call = sim.wait(timeout=10, ident="chief.settings.call")
    run.check(p, "Chief info has a Call action", call is not None)
    sim.shot("30-chief-info")
    if call:
        sim.tap_el(call)
    run.check(p, "Call opens the call screen", sim.wait(timeout=10, ident="chief.call") is not None)
    reply = None
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline and reply is None:
        if "Chief just replied" in " ".join(sim.texts()):
            reply = True
        time.sleep(0.7)
    time.sleep(6)  # the spoken reply finishes
    sim.shot("31-live-after-reply")
    sim.tap_q(ident="chief.call.minimize")
    pill = sim.wait(timeout=8, ident="chief.call.pill")
    run.check(p, "Minimize leaves the call running as a pill over the app", pill is not None)
    sim.shot("32-pill")
    if pill:
        sim.tap_el(pill)
    run.check(p, "The pill brings the call back", sim.wait(timeout=8, ident="chief.call.captions") is not None)
    sim.tap_q(ident="chief.call.keyboard")
    draft = sim.wait(timeout=6, ident="chief.call.draft")
    if draft:
        sim.tap_el(draft)
        time.sleep(1)
        sim.softtype("Also open a PR when they pass")
        sim.shot("33-typing")
        sim.tap_q(ident="chief.call.sendDraft")
    got = None
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and not got:
        if "You wrote: Also open a PR" in " ".join(sim.texts()):
            got = True
        time.sleep(0.5)
    run.check(p, "A typed message is a turn Chief answers", bool(got))
    sim.tap_q(ident="chief.call.keyboard")
    time.sleep(1)
    speaker = sim.wait(timeout=4, ident="chief.call.speaker")
    if speaker:
        sim.tap_el(speaker)
    mute = sim.wait(timeout=4, ident="chief.call.mute")
    if mute:
        sim.tap_el(mute)
    time.sleep(1)
    status = text_of(sim, "chief.call.status")
    mute = sim.wait(timeout=4, ident="chief.call.mute")
    speaker = sim.wait(timeout=4, ident="chief.call.speaker")
    run.check(p, "Mute and Speaker toggle", mute is not None and mute.value == "On" and speaker is not None and speaker.value == "Off",
              f"mute={getattr(mute, 'value', None)} speaker={getattr(speaker, 'value', None)} status={status!r}")
    sim.shot("34-muted-earpiece")
    sim.tap_q(ident="chief.call.end")
    ended = wait_label(sim, "chief.call.status", ["ended"], 10)
    run.check(p, "End hangs up", "ended" in ended, ended)
    sim.shot("35-ended")
    sim.tap_q(ident="chief.call.done")
    time.sleep(1)
    sim.record_stop()
    # Settings root row and the page with the demo placeholder key.
    sim.launch(BUNDLE, args=["-cmux-mobile-settings-page", "chiefCalls"], env={"CMUX_MOBILE_MOCK_AUTH": "1", "CMUX_MOBILE_CALL_DEMO": "hold"})
    time.sleep(3)
    sim.shot("36-settings-chief-calls")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", default=os.path.expanduser(f"~/call-chief-aziz/verify-{datetime.datetime.now():%Y%m%d-%H%M%S}"))
    ap.add_argument("--sim-name", default="cmux-callchief")
    ap.add_argument("--phases", default="nokey,real401,call,hold")
    ap.add_argument("--keep-sim", action="store_true")
    a = ap.parse_args()
    run = Run(a.out)
    udid = ensure_sim(a.sim_name, run)
    sim = Sim(udid, shots_dir=os.path.join(a.out, "shots"))
    phases = {"nokey": phase_nokey, "real401": phase_real401, "call": phase_call, "hold": phase_hold}
    try:
        for name in a.phases.split(","):
            run.log(f"=== phase {name}")
            try:
                phases[name](sim, a.app, run)
            except Exception as error:  # a phase that breaks is a failed check, the rest still run
                sim.record_stop()
                sim.shot(f"error-{name}")
                run.check(name, "phase ran to the end", False, f"{type(error).__name__}: {error}")
    finally:
        run.save()
        if not a.keep_sim:
            sh("xcrun", "simctl", "shutdown", udid, check=False)
            sh("xcrun", "simctl", "delete", udid, check=False)
            run.log("simulator shut down and deleted")
    failed = [c for c in run.results["checks"] if not c["ok"]]
    run.log(f"{len(run.results['checks']) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
