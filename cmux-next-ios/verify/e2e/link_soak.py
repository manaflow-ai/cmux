#!/usr/bin/env python3
"""Link reliability soak (verify/link-reliability-20261023.md): one headless simulator on
this mini runs the Demo app; one or two hidden rig Mac apps (verify/multimac/rig.py, real
tagged cmux-next dev builds, settings only through `open --env`) run on other cmux minis.
Signaling is the dev Worker, relays are Cloudflare TURN, so the link is the real one: no
local socket, loopback or direct shortcut.

    python3 -u link_soak.py --app CmuxMobileApp.app --sim cmux-<tag> \
        --rig HOST:RIGDIR:WORKSPACE [--rig HOST:RIGDIR:WORKSPACE] --minutes 30 --out DIR \
        [--relay-only] [--block-udp] [--no-webrtc-media] [--transport wireguard|webrtc] \
        [--browser URL] [--reuse] [--event bg:SECONDS@MIN] [--event kill@MIN] [--event hostd@MIN]

The phone opens each rig's workspace (a terminal printing the time every 200 ms) in
turn, and with --browser a browser workspace on the first rig showing URL. Every minute
it types a marker into the terminal on screen and reads it back from that Mac's own CLI
(echo latency). `--event` adds app-state and Mac events at a minute mark: `bg:S` sends
the app to the background for S seconds, `kill` kills and relaunches it, `hostd` kills
the first rig's cmux-mobile-host (the app restarts it). At the end the rigs' host logs and
the phone's library log (stderr, CMUX_MOBILE_LOG) are parsed into results.json: every
link up (path, link_ready), path change, link down (reason), media session up or failure,
and the gap from each drop to the next link up.
"""
import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from journey import BUNDLE, Fail, Journey, check  # noqa: E402
from sim import Sim, sh  # noqa: E402

DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
STREAM = "while :; do date +lrsoak-%H:%M:%S; sleep 0.2; done"
RELAY_LOCK = __import__("threading").Lock()
TS = r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z"


def utc(epoch=None):
    return datetime.datetime.fromtimestamp(epoch or time.time(), datetime.timezone.utc).strftime("%H:%M:%S")


def epoch_of(ts):
    return datetime.datetime.strptime(ts[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp()


class Rig:
    """A rig Mac app on a mini, driven only through its own CLI over ssh."""

    def __init__(self, spec):
        self.host, self.dir, self.workspace = spec.split(":")
        self.terminal = None

    def ssh(self, cmd, timeout=90):
        if os.environ.get("LINKSOAK_RELAY"):
            # The simulator mini has no ssh to the rig minis: the laptop that started this
            # (link_soak_relay.py) runs the command and answers on stdin.
            with RELAY_LOCK:
                sys.stdout.write("@@RIG " + json.dumps({"host": self.host, "cmd": cmd, "timeout": timeout}) + "\n")
                sys.stdout.flush()
                reply = json.loads(sys.stdin.readline() or '{"rc": 255, "out": "", "err": "relay gone"}')
            return subprocess.CompletedProcess(cmd, reply["rc"], reply["out"], reply["err"])
        return subprocess.run(["ssh", "-o", "ConnectTimeout=10", self.host, cmd], capture_output=True, text=True, timeout=timeout)

    def rig(self, *args, timeout=90):
        return self.ssh(f"cd {self.dir} && python3 rig.py " + " ".join(shlex.quote(x) for x in args), timeout=timeout)

    def cmux(self, *args, json_out=False, check=True):
        r = self.rig("cli", *((["--json"] if json_out else []) + list(args)))
        if check and r.returncode != 0:
            raise RuntimeError(f"{self.host} cmux {' '.join(args)}: {(r.stderr or r.stdout).strip()[:300]}")
        if json_out and r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
        return r

    def seed(self):
        """A workspace whose terminal streams output (a busy terminal, as an agent's)."""
        r = self.cmux("workspace", "create", "--name", self.workspace, json_out=True)["value"]
        self.terminal = r["terminal_id"]
        self.cmux("terminal", self.terminal, "write", "--text", STREAM + "\n")
        return self.terminal

    def screen(self):
        return (self.cmux("terminal", self.terminal, "screen", "read", json_out=True) or {}).get("text", "")

    def hostd_log(self):
        state = self.rig("status").stdout
        r = self.ssh(f"cd {self.dir} && python3 -c 'import rig; print(rig.mac().hostd_state)'")
        path = r.stdout.strip() + "/cmux-mobile-host.log"
        return self.ssh(f"cat {shlex.quote(path)}", timeout=120).stdout, state


def ensure_sim(name, runtime, reuse):
    for devs in json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"].values():
        for d in devs:
            if d["name"] == name:
                if reuse:
                    sh("xcrun", "simctl", "boot", d["udid"], check=False)
                    sh("xcrun", "simctl", "bootstatus", d["udid"], "-b", timeout=600)
                    return d["udid"]
                sh("xcrun", "simctl", "delete", d["udid"], check=False)
    udid = sh("xcrun", "simctl", "create", name, DEVICE, runtime).strip()
    sh("xcrun", "simctl", "boot", udid)  # headless; Simulator.app is never opened
    sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
    return udid


def onboard(sim, log):
    """From the welcome screen to the tab bar (the production account's path)."""
    tabs = dict(label="Workspaces", kind="RadioButton")
    deadline = time.time() + 240
    while time.time() < deadline:
        if sim.find(**tabs) and not sim.find(contains="Connect your Mac"):
            log("onboarded: on the tab bar")
            return
        personal = sim.find(ident="setup.teams.personal") or sim.find(contains="Personal", kind="Button")
        hit = (sim.find(ident="setup.teams.choose") and personal) or sim.find(label="Not now", kind="Button") \
            or (sim.find(contains="Connect your Mac") and sim.find(label="Continue", kind="Button"))
        if hit:
            sim.tap_el(hit[0])
        time.sleep(1.5)
    raise Fail("never reached the tab bar")


def parse_host(text, since, phone=None):
    """The rig Mac's link and media events since `since` (epoch)."""
    out = []
    for line in text.splitlines():
        m = re.match(TS + r" +\w+ (\S+): (.*)", line)
        if not m or epoch_of(m.group(1)) < since:
            continue
        t, body = epoch_of(m.group(1)), m.group(3)
        sid = (re.search(r'session_id="([0-9a-f-]{8})', body) or [None, None])[1]
        if body.startswith("link up") and (phone is None or phone in body):
            out.append({"t": t, "ev": "up", "sid": sid, "path": re.search(r"path=(\w+)", body).group(1),
                        "link_ready_ms": float((re.search(r"link_ready=([\d.]+)ms", body) or [0, 0])[1])})
        elif body.startswith("link down"):
            out.append({"t": t, "ev": "down", "sid": sid, "reason": (re.search(r'reason="([^"]*)"', body) or [0, ""])[1]})
        elif body.startswith("link path changed"):
            out.append({"t": t, "ev": "path", "sid": sid, "path": re.search(r"path=(\w+)", body).group(1)})
        elif body.startswith("media session up"):
            out.append({"t": t, "ev": "media_up", "path": (re.search(r"path=(\w+)", body) or [0, ""])[1],
                        "link": (re.search(r'link_session="([0-9a-f-]{8})', body) or [0, ""])[1]})
        elif body.startswith("media session failed"):
            out.append({"t": t, "ev": "media_failed", "error": (re.search(r"error=(.*?) timings=", body) or [0, body[-80:]])[1],
                        "link": (re.search(r'link_session="([0-9a-f-]{8})', body) or [0, ""])[1]})
        elif body.startswith("media session down"):
            out.append({"t": t, "ev": "media_down", "reason": (re.search(r'reason="([^"]*)"', body) or [0, ""])[1]})
        elif body.startswith("signaling ended"):
            out.append({"t": t, "ev": "signaling_down", "reason": (re.search(r'reason="([^"]*)"', body) or [0, ""])[1][:80]})
        elif body.startswith("signaling connected"):
            out.append({"t": t, "ev": "signaling_up"})
    return out


def summarize(events):
    ups = [e for e in events if e["ev"] == "up"]
    downs = [e for e in events if e["ev"] == "down"]
    gaps = []
    for d in downs:
        nxt = next((u for u in ups if u["t"] >= d["t"]), None)
        gaps.append(round(nxt["t"] - d["t"], 2) if nxt else None)
    lifetimes = []
    for u in ups:
        d = next((x for x in downs if x["sid"] == u["sid"] and x["t"] >= u["t"]), None)
        lifetimes.append(round((d["t"] if d else time.time()) - u["t"], 1))
    paths = {}
    for e in events:
        if e["ev"] in ("up", "path"):
            paths[e["path"]] = paths.get(e["path"], 0) + 1
    return {
        "link_ups": len(ups), "link_downs": len(downs),
        "link_ready_ms": [u["link_ready_ms"] for u in ups],
        "down_reasons": [d["reason"] for d in downs], "reconnect_s": gaps, "lifetimes_s": lifetimes,
        "paths": paths,
        "media_up": [e["path"] for e in events if e["ev"] == "media_up"],
        "media_failed": [e["error"][:60] for e in events if e["ev"] == "media_failed"],
        "signaling_resets": len([e for e in events if e["ev"] == "signaling_down"]),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--sim", required=True, help="simulator name; the rigs' pairing seed names it")
    ap.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-26-5")
    ap.add_argument("--rig", action="append", required=True)
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--out", required=True)
    ap.add_argument("--relay-only", action="store_true")
    ap.add_argument("--block-udp", action="store_true")
    ap.add_argument("--no-webrtc-media", action="store_true")
    ap.add_argument("--transport", default="wireguard", choices=["wireguard", "webrtc"])
    ap.add_argument("--browser")
    ap.add_argument("--reuse", action="store_true", help="keep the signed-in simulator of a previous run")
    ap.add_argument("--event", action="append", default=[])
    ap.add_argument("--phone-log", default="info,cmux_mobile_link=debug")
    ap.add_argument("--bundle", default=BUNDLE)
    ap.add_argument("--creds", help="EMAIL=/PASSWORD= file: a non-DEBUG simulator build signs in with it")
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "shots"), exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{utc()} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    rigs = [Rig(s) for s in a.rig]
    for rig in rigs:
        rig.device = rig.rig("device-id").stdout.strip()
        rig.seed()
        log(f"rig {rig.host}: device {rig.device}, workspace {rig.workspace}, terminal {rig.terminal}")
    udid = ensure_sim(a.sim, a.runtime, a.reuse)
    sim = Sim(udid, shots_dir=os.path.join(a.out, "shots"))
    # Keep the app's info and debug lines (link phases, probes, presence) in the simulator's log store.
    for sub in ("dev.cmux.mobile", "dev.cmux"):
        subprocess.run(["xcrun", "simctl", "spawn", udid, "log", "config", "--subsystem", sub, "--mode", "level:debug,persist:debug"],
                       capture_output=True)
    j = Journey(sim, rigs[0], a.out, a.app, log)
    env = {"CMUX_MOBILE_LOG": a.phone_log}
    if a.relay_only:
        env["CMUX_MOBILE_DEV_RELAY_ONLY"] = "1"
    if a.block_udp:
        env["CMUX_MOBILE_DEV_BLOCK_UDP"] = "1"
    if a.no_webrtc_media:
        env["CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA"] = "1"
    phone_log = os.path.join(a.out, "phone-stderr.log")

    def launch():
        e = dict(os.environ, **{"SIMCTL_CHILD_" + k: v for k, v in env.items()})
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", f"--stderr={phone_log}.{int(time.time())}",
                        udid, a.bundle], check=True, capture_output=True, env=e)

    if a.creds:
        pairs = dict(l.strip().split("=", 1) for l in open(os.path.expanduser(a.creds)) if "=" in l)
        if not a.reuse:
            sh("xcrun", "simctl", "terminate", udid, a.bundle, check=False)
            subprocess.run(["xcrun", "simctl", "uninstall", udid, a.bundle], capture_output=True)
            subprocess.run(["xcrun", "simctl", "keychain", udid, "reset"], capture_output=True)
            sh("xcrun", "simctl", "install", udid, a.app)
        # The password sign-in of a non-DEBUG simulator build reads these once (never logged).
        env.update(CMUX_MOBILE_STACK_EMAIL=pairs["EMAIL"], CMUX_MOBILE_STACK_PASSWORD=pairs["PASSWORD"])
        launch()
        if not a.reuse:
            onboard(sim, log)
    else:
        if not a.reuse:
            j.s_fresh_install()
            j.s_sign_in()
            j.s_choose_space()
        launch()
    t0 = time.time()
    log(f"app launched with {sorted(env)}; soak {a.minutes} min")
    if a.transport == "webrtc":
        j.back_to_list()
        j.open_transport_page()
        sim.tap_el(sim.find(ident="settings.transport.webrtc")[0])
        time.sleep(0.5)
        j.close_transport_page()

    def open_ws(rig):
        j.back_to_list()
        row = sim.wait(prefix=rig.workspace, kind="Button", timeout=60)
        check(row, f"{rig.workspace} ({rig.host}) not listed on the phone")
        sim.tap_el(row)
        check(sim.wait(ident="terminal.composer.field", timeout=40), f"{rig.workspace}: no terminal")

    for rig in rigs:
        open_ws(rig)
    sim.shot("terminal-open")
    if a.browser:
        import transport_verify as tv
        holder = tv.TV.__new__(tv.TV)
        holder.j, holder.sim = j, sim
        tv.TV.open_browser(holder, a.browser)
        log(f"browser workspace opened on {a.browser}")
        time.sleep(5)
        sim.shot("browser-open")
    def run_event(what):
        if what.startswith("bg:"):
            sim.home()
            time.sleep(float(what.split(":")[1]))
            # Back to the foreground: the same process (no terminate), as tapping its icon.
            e = dict(os.environ, **{"SIMCTL_CHILD_" + k: v for k, v in env.items()})
            subprocess.run(["xcrun", "simctl", "launch", udid, a.bundle], capture_output=True, env=e)
        elif what == "kill":
            sh("xcrun", "simctl", "terminate", udid, a.bundle, check=False)
            launch()
            open_ws(rigs[-1])
        elif what == "hostd":
            rigs[0].ssh(f"cd {rigs[0].dir} && pkill -9 -f \"$(python3 -c 'import rig; print(rig.mac().app)')/Contents/Resources/bin/cmux-mobile-host\"")

    events = {}
    for spec in a.event:
        what, minute = spec.split("@")
        events[float(minute)] = what
    echoes = []
    n = 0
    end = t0 + a.minutes * 60
    next_echo = time.time() + 30
    while time.time() < end:
        now = time.time()
        due = [m for m in list(events) if now >= t0 + m * 60]
        for m in due:
            what = events.pop(m)
            log(f"event {what}")
            try:
                run_event(what)
            except Exception as error:  # a step that fails is a result, not the end of the soak
                log(f"event {what} failed: {str(error)[:200]}")
            sim.shot(f"after-{what.replace(':', '-')}")

        # A browser run keeps the page on screen (the media session's use); liveness then
        # comes from the Macs' logs only.
        if now >= next_echo and not a.browser:
            next_echo = now + 60
            n += 1
            rig = rigs[(n - 1) % len(rigs)] if len(rigs) > 1 else rigs[0]
            try:
                if len(rigs) > 1:
                    open_ws(rig)
                marker = f"lrm{n:03d}"
                comp = sim.wait(ident="terminal.composer.field", timeout=10)
                check(comp, "no composer")
                sim.tap_el(comp)
                time.sleep(0.4)
                sim.softtype(f"{marker}\n")
                t_type = time.time()
                seen = False
                while time.time() - t_type < 20:
                    if marker in rig.screen():
                        seen = True
                        break
                    time.sleep(0.3)
                rec = {"n": n, "t": utc(t_type), "mac": rig.host, "reached": seen, "echo_s": round(time.time() - t_type, 2)}
            except Exception as error:  # an echo that fails is a result, not the end of the soak
                rec = {"n": n, "t": utc(), "mac": rig.host, "reached": False, "error": str(error)[:200]}
            echoes.append(rec)
            log(f"echo {rec}")
            j.hide_keyboard()
        time.sleep(2)
    sim.shot("end")
    results = {"args": vars(a), "t0": utc(t0), "minutes": round((time.time() - t0) / 60, 1), "echoes": echoes, "rigs": []}
    for rig in rigs:
        text, _ = rig.hostd_log()
        open(os.path.join(a.out, f"hostd-{rig.host}.log"), "w").write(text)
        ev = parse_host(text, t0)
        results["rigs"].append({"host": rig.host, "events": ev, "summary": summarize(ev)})
        log(f"{rig.host}: {json.dumps(summarize(ev))}")
    phone = ""
    for f in sorted(os.listdir(a.out)):
        if f.startswith("phone-stderr.log."):
            phone += open(os.path.join(a.out, f), errors="replace").read()
    results["phone_lines"] = [l[:300] for l in phone.splitlines()
                              if re.search(r"TURN|roam|route|reach|media session|link (up|down)|keepalive|WireGuard", l)][-400:]
    ok = sum(1 for e in echoes if e["reached"])
    results["echo_ok"] = f"{ok}/{len(echoes)}"
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=2)
    log(f"done: echoes {ok}/{len(echoes)}")


if __name__ == "__main__":
    try:
        main()
    except Fail as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
