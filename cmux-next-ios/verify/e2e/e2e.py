#!/usr/bin/env python3
"""cmux-next-ios end-to-end rig: real tagged cmux-next Mac app (hidden, isolated) +
the iOS app in ONE headless simulator, the production journey, latency metrics.

See run.sh for usage. Results: verify/evidence/<date>/e2e/<run>/results.json.
"""
import argparse
import datetime
import glob
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CNX = os.path.abspath(os.path.join(HERE, "../.."))
sys.path.insert(0, HERE)
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

from sim import Sim  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from journey import Journey  # noqa: E402
from latency import Latency  # noqa: E402

RUNTIMES = {"26": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "27": "com.apple.CoreSimulator.SimRuntime.iOS-27-0"}
DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"


def sh(*a, **k):
    return subprocess.run(list(a), capture_output=True, text=True, **k)


def newest_mac_app():
    apps = sorted(glob.glob(os.path.expanduser("~/cmux-mobile-builds/*-e2e/app/cmux DEV *.app")), key=os.path.getmtime)
    if not apps:
        sys.exit("no Mac app: pass --mac-app or fetch a fleet build (run.sh fetch-mac JOB_ID)")
    return apps[-1]


def ensure_xcframework(log):
    """CmuxMobileLinkFFI.xcframework (gitignored) for this checkout's Rust sources: the demo-build cache
    (same key as scripts/demo-build.sh), else built with JOBS=4 and cached."""
    import shutil
    repo = os.path.dirname(CNX)
    trees = [sh("git", "-C", repo, "rev-parse", f"HEAD:{p}").stdout.strip()
             for p in ("cmux-next-ios/rust", "cmux-tui/crates/cmux-wg", "cmux-tui/crates/cmux-transport")]
    import hashlib
    key = hashlib.sha1(("\n".join(trees) + "\n").encode()).hexdigest()[:16]
    dest = os.path.join(CNX, "CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework")
    stamp = dest + ".key"
    if os.path.isdir(dest) and os.path.exists(stamp) and open(stamp).read().strip() == key:
        return
    cache = os.path.expanduser(f"~/cmux-mobile-builds/.cache/xcframework/{key}/CmuxMobileLinkFFI.xcframework")
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    if os.path.isdir(cache):
        log(f"CmuxMobileLinkFFI.xcframework: cache hit {key}")
        shutil.copytree(cache, dest, symlinks=True)
    else:
        log(f"CmuxMobileLinkFFI.xcframework: building {key} (JOBS=4)")
        r = subprocess.run(["bash", os.path.join(CNX, "rust/scripts/build-xcframework.sh")], env=dict(os.environ, JOBS="4"))
        if r.returncode:
            sys.exit("CmuxMobileLinkFFI.xcframework build failed")
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        shutil.copytree(dest, cache, symlinks=True)
    open(stamp, "w").write(key)


def build_ios(log, config):
    ensure_xcframework(log)
    log(f"building the iOS app ({config}, arm64, -jobs 4)")
    r = sh("xcodegen", "generate", "-q", cwd=CNX)
    if r.returncode:
        sys.exit(r.stderr)
    logf = os.path.join(CNX, "build", f"e2e-{config}.log")
    os.makedirs(os.path.dirname(logf), exist_ok=True)
    cmd = ["xcodebuild", "-project", "CmuxMobileApp.xcodeproj", "-scheme", "CmuxMobileApp", "-configuration", config,
           "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", "build/dd", "-jobs", "4",
           "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM="]
    if config == "Demo":
        cmd.append("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO")
    with open(logf, "w") as f:
        rc = subprocess.run(cmd + ["build"], cwd=CNX, stdout=f, stderr=subprocess.STDOUT).returncode
    if rc:
        sys.exit(f"iOS build failed; see {logf}")
    return os.path.join(CNX, f"build/dd/Build/Products/{config}-iphonesimulator/CmuxMobileApp.app")


def ensure_sim(name, runtime, log):
    lst = json.loads(sh("xcrun", "simctl", "list", "devices", "-j").stdout)
    udid = None
    for rt, devs in lst["devices"].items():
        for d in devs:
            if d["name"] == name:
                udid = d["udid"]
    if not udid:
        udid = sh("xcrun", "simctl", "create", name, DEVICE, runtime).stdout.strip()
        log(f"created simulator {name} {udid}")
    sh("xcrun", "simctl", "boot", udid)  # headless; Simulator.app is never opened
    sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
    return udid


def mac_windows_on_agent_display(pid):
    """Window placement check: agent GUI only on the LG HDR 4K, never the primary display."""
    code = ('import AppKit, CoreGraphics\n'
            'let scr = NSScreen.screens.map { ($0.localizedName, $0.frame) }\n'
            'let primaryH = NSScreen.screens.first!.frame.height\n'
            f'let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]\n'
            f'for w in l where (w["kCGWindowOwnerPID"] as? Int) == {pid} {{\n'
            '  let b = w["kCGWindowBounds"] as! [String: Any]\n'
            '  let x = (b["X"] as! NSNumber).doubleValue, y = (b["Y"] as! NSNumber).doubleValue\n'
            '  let p = CGPoint(x: x + 20, y: primaryH - y - 20)\n'
            '  let s = scr.first { $0.1.contains(p) }?.0 ?? "offscreen"\n'
            '  print("\\(s)|\\(Int(x)),\\(Int(y))")\n'
            '}\n')
    r = sh("swift", "-e", code, timeout=120)
    return [l for l in r.stdout.splitlines() if "|" in l]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", help="tagged cmux-next dev .app (default: newest ~/cmux-mobile-builds/*-e2e/app)")
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--sim-name")
    ap.add_argument("--config", default="Demo", choices=["Demo", "Debug"])
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--steps", help="comma list of journey step ids")
    ap.add_argument("--skip", default="", help="comma list of journey step ids to skip")
    ap.add_argument("--latency", default="all", help="'all', 'none' or a comma list of metrics")
    ap.add_argument("--samples", type=int, default=20)
    ap.add_argument("--max-load", type=float, help="load gate: before each latency sample, wait (up to 5 min) for this Mac's 1-minute load average to be at or under this")
    ap.add_argument("--keep", action="store_true", help="leave the Mac app running and the simulator booted")
    ap.add_argument("--out")
    a = ap.parse_args()

    mac_app = os.path.abspath(a.mac_app or newest_mac_app())
    # Before anything builds or launches: one rig per dev account at a time.
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    sim_name = a.sim_name or ("cmux-mobile-e2e2-ios26" if a.ios == "26" else "cmux-mobile-e2e2-ios27")
    stamp = datetime.datetime.now().strftime("%Y-%m-%d")
    run = datetime.datetime.now().strftime("%H%M%S") + f"-ios{a.ios}"
    out = a.out or os.path.join(CNX, "verify/evidence", stamp, "e2e", run)
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    head = sh("git", "-C", CNX, "rev-parse", "HEAD").stdout.strip()
    app_path = os.path.join(CNX, f"build/dd/Build/Products/{a.config}-iphonesimulator/CmuxMobileApp.app") if a.no_build else build_ios(log, a.config)
    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app).prepare()
    # The rig's simulator pairs without the Mac's person-only prompt (DEBUG seed).
    mac.seed_pairing(names=[sim_name])
    log(f"Mac app {os.path.basename(mac_app)} ({mac.bundle_id}), rig {rig}, settings {mac.config}")
    udid = ensure_sim(sim_name, RUNTIMES[a.ios], log)
    sim = Sim(udid, os.path.join(out, "shots"))
    meta = {"date": stamp, "run": run, "ios_head": head, "ios_config": a.config, "ios_runtime": RUNTIMES[a.ios],
            "simulator": {"name": sim_name, "udid": udid}, "mac_app": os.path.basename(mac_app),
            "mac_bundle_id": mac.bundle_id, "mac_tag": mac.tag,
            "mac_source": open(os.path.join(os.path.dirname(os.path.dirname(mac_app)), "SOURCE")).read().strip()
            if os.path.exists(os.path.join(os.path.dirname(os.path.dirname(mac_app)), "SOURCE")) else None}
    results, metrics, j = [], {}, None
    try:
        t = time.time()
        mac.launch()
        hostd = mac.wait_hostd(120)
        meta["mac_launch_s"] = round(time.time() - t, 2)
        meta["mac_windows"] = mac_windows_on_agent_display(mac.pid)
        log(f"Mac app up (pid {mac.pid}), cmux-mobile-host {'running' if hostd else 'NOT running'}, windows {meta['mac_windows']}")
        if any(w.startswith("LG UltraFine") for w in meta["mac_windows"]):
            log("WARNING: a rig window is on the primary display")
        j = Journey(sim, mac, out, app_path, log)
        results = j.run(only=set(a.steps.split(",")) if a.steps else None, skip=set(filter(None, a.skip.split(","))))
        if a.latency != "none":
            log("latency")
            which = None if a.latency == "all" else set(a.latency.split(","))
            metrics = Latency(j, os.path.join(out, "latency"), log, a.samples, a.max_load).run(which)
        j.run(only=set(a.steps.split(",")) if a.steps else None, skip=set(filter(None, a.skip.split(","))), last=True)
    finally:
        if j:
            results = j.results
        doc = {"meta": meta, "steps": results, "latency": metrics, "hangs": j.hangs if j else [],
               "summary": {s: sum(1 for r in results if r["status"] == s) for s in ("pass", "fail", "blocked")}}
        for r in doc["steps"]:
            if r.get("screenshot"):
                r["screenshot"] = os.path.relpath(r["screenshot"], out)
        json.dump(doc, open(os.path.join(out, "results.json"), "w"), indent=2, default=str)
        log(f"results: {doc['summary']} -> {os.path.join(out, 'results.json')}")
        if not a.keep:
            log(f"quitting the rig Mac app: {mac.quit()}")
            sh("xcrun", "simctl", "shutdown", udid)
            sh("xcrun", "simctl", "delete", udid)
            log(f"simulator {sim_name} shut down and deleted")
        log("rig done")


if __name__ == "__main__":
    main()
