"""Live WireGuard roaming probe: a rig Mac app (ROAM_MAC_APP; its bundled cmux-mobile-host
should carry the roaming code) + one Debug simulator build on WireGuard. The seed
terminal streams output; the app is relaunched with CMUX_MOBILE_NETWORK_PROBE=roam|loss and
logs network_probe {json} (stall_ms = longest wait for a link pong after the change).

    python3 verify/e2e/roam_probe.py roam loss

Waits for nobody: it exits when another rig run is active. Quits its Mac app and
deletes its simulator at the end."""
import json, os, subprocess, sys, time
CNX = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, os.path.join(CNX, "verify/e2e"))
from e2e import ensure_sim, RUNTIMES, mac_windows_on_agent_display  # noqa: E402
from mac import Mac, refuse_other_rigs, pb  # noqa: E402
from sim import Sim  # noqa: E402
from journey import Journey, BUNDLE  # noqa: E402

MAC_APP = os.path.expanduser(os.environ.get("ROAM_MAC_APP", "~/cmux-mobile-builds/20261014-wgroam-live/app/cmux DEV cmux-mobile-e2e-wgroam01.app"))
APP = os.path.join(CNX, "build/dd/Build/Products/Debug-iphonesimulator/CmuxMobileApp.app")
SIM = "cmux-mobile-wgroam-ios26"
OUT = os.path.join(CNX, "verify/evidence", time.strftime("%Y-%m-%d"), "wgroam-live")
os.makedirs(OUT, exist_ok=True)
logf = open(os.path.join(OUT, "run.log"), "a")


def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    logf.write(line + "\n"); logf.flush()


def probe_lines(udid, since):
    r = subprocess.run(["xcrun", "simctl", "spawn", udid, "log", "show", "--style", "compact", "--start", since,
                        "--predicate", 'subsystem == "dev.cmux.mobile" AND eventMessage CONTAINS "network_probe {"'],
                       capture_output=True, text=True, timeout=120)
    return [l for l in r.stdout.splitlines() if "network_probe {" in l]


def main():
    from mac import running_rig_apps
    alive = [a for a in running_rig_apps() if subprocess.run(["ps", "-p", str(a[0])], capture_output=True).returncode == 0]
    if alive or subprocess.run(["pgrep", "-f", "Python e2e.py --mac-app"], capture_output=True).returncode == 0:
        sys.exit(f"rig busy: {alive}")
    mac = Mac(os.path.expanduser("~/cmux-next-ios-e2e/wgroam"), MAC_APP).prepare()
    mac.seed_pairing(names=[SIM])
    udid = ensure_sim(SIM, RUNTIMES["26"], log)
    sim = Sim(udid, os.path.join(OUT, "shots"))
    results = {}
    try:
        mac.launch()
        log(f"Mac up pid {mac.pid}, hostd {'running' if mac.wait_hostd(120) else 'NOT running'}, windows {mac_windows_on_agent_display(mac.pid)}")
        j = Journey(sim, mac, OUT, APP, log)
        res = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        log(f"setup: {[(r['id'], r['status'], (r.get('notes') or '')[:80]) for r in res]}")
        j.tab("Settings")
        row = j.settings_find(contains="Transport")
        if not row:
            raise SystemExit("no Transport row in Settings")
        sim.tap_el(row); time.sleep(1.5)
        wg = sim.wait(ident="settings.transport.wireguard", timeout=8)
        if not wg:
            raise SystemExit("no WireGuard choice on the Transport page")
        sim.tap_el(wg); t = time.time()
        j.tab("Workspaces")
        lab = ""
        while time.time() - t < 40:
            lab = j.link_status()
            if "Connected" in lab and "wireguard" in lab.lower():
                break
            time.sleep(0.5)
        log(f"WireGuard: {lab!r} after {time.time() - t:.1f} s")
        # Terminal output streams on the Mac's seed terminal for the whole run.
        j.mac.cmux("terminal", j.seed["term1"], "write", "--text",
                   "while true; do date +%H:%M:%S.%N; sleep 0.02; done\n")
        for mode in sys.argv[1:] or ["loss", "roam"]:
            since = time.strftime("%Y-%m-%d %H:%M:%S")
            sim.launch(BUNDLE, env={"CMUX_MOBILE_NETWORK_PROBE": mode, "CMUX_MOBILE_NETWORK_PROBE_DELAY": "15"})
            try:
                j.open_seed_workspace()
                log(f"{mode}: terminal open on the phone")
            except Exception as e:  # the probe still runs
                log(f"{mode}: could not open the terminal: {e}")
            wait = 15 + 1 + (20 if mode == "loss" else 3) + 25
            t = time.time()
            lines = []
            while time.time() - t < wait + 30:
                time.sleep(5)
                lines = probe_lines(udid, since)
                if lines:
                    break
            sim.shot(f"after-{mode}")
            raw = lines[-1].split("network_probe ", 1)[1] if lines else None
            results[mode] = json.loads(raw) if raw else None
            log(f"{mode}: {raw}")
        json.dump(results, open(os.path.join(OUT, "results.json"), "w"), indent=2)
    finally:
        log(f"quitting the rig Mac app: {mac.quit()}")
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)
        log("simulator deleted")


main()
