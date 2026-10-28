"""G-17: the old-SHA regression runner (ACCEPTANCE §13, T-REG). It installs a build (an old
SHA's Demo build from `scripts/demo-build.sh --ref SHA --tag rSHA8`, or the new build),
runs one named scenario on a rig instance (phone app -> real link -> cmux-mobile-host -> daemon
-> PTY; every command typed on the phone), records the simulator with a touch log, and
writes one verdict per T-REG row. `both` runs the old build then the new one and passes
only when the old one is red and the new one green.

    python3 reg.py builds
    python3 reg.py run SCENARIO BUILD [--agent codexlike|codex]
    python3 reg.py both SCENARIO OLD_BUILD [NEW_BUILD=new] [--agent ...]

SCENARIO: 1259 (black frames and jumps while following and scrolling a working agent),
1337 (near-bottom oscillation with the agent idle), 1350 (grid card and phantom card).
BUILD: a key of BUILDS (224d15e9, 2e1369f0, new). Rig instance: TQ_STATE/TQ_HOST/
TQ_RBASE/TQ_RAW (tq.py). Output: design/terminal/reg/<scenario>/<build>-<time>.json and
the recording in TQ_RAW.

--agent codexlike (default) runs fixtures/codexlike.py, staged on the Mac at ~/tqf: the
D2 mechanism (an inline TUI that erases and redraws its live area) with no model. It is a
fixture, not real Codex: §13 asks for real Codex, so a codexlike verdict is a
reproduction of the mechanism, not the row's pass. --agent codex starts the real Codex
CLI (it needs a Codex login on the rig's Mac) and prompts it on the phone.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
import zipfile

import tq
from tq import ctx, load, save, log, rsh

HERE = tq.HERE
OUT = os.path.abspath(os.path.join(HERE, "../design/terminal/reg"))
APPS = os.path.expanduser("~/cmux-next-ios-e2e/reg/apps")
BUILDS_ROOT = os.path.expanduser("~/cmux-mobile-builds")
BUILDS = {
    "224d15e9": {"sha": "224d15e90f", "zip": "20261015-224d15e90f-r224d15e9/ios-simulator/cmux-mobile-r224d15e9-sim.app.zip"},
    "2e1369f0": {"sha": "2e1369f054", "zip": "20261015-2e1369f054-r2e1369f0/ios-simulator/cmux-mobile-r2e1369f0-sim.app.zip"},
    "new": {"sha": None, "app": None},  # the state file's app_path
}
TOUCH = []


def touch(kind, dur=None):
    TOUCH.append({"t": round(time.time(), 3), "kind": kind, **({"dur": dur} if dur is not None else {})})


def plist(app, key):
    return subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", os.path.join(app, "Info.plist")],
                          capture_output=True, text=True).stdout.strip()


def app_for(build):
    b = BUILDS[build]
    if build == "new":
        app = load()["app_path"]
    else:
        dest = os.path.join(APPS, build)
        apps = [a for a in os.listdir(dest) if a.endswith(".app")] if os.path.isdir(dest) else []
        if not apps:
            os.makedirs(dest, exist_ok=True)
            subprocess.run(["ditto", "-x", "-k", os.path.join(BUILDS_ROOT, b["zip"]), dest], check=True)
            apps = [a for a in os.listdir(dest) if a.endswith(".app")]
        app = os.path.join(dest, apps[0])
    return app, plist(app, "CFBundleIdentifier")


def install(build):
    """Install the build (each has its own bundle id, so the builds sit side by side and
    each keeps its sign-in) and bring it to the rig's seed workspace on terminal tab t1."""
    import journey
    app, bundle = app_for(build)
    sim, mac, j = ctx()
    tq.BUNDLE = journey.BUNDLE = bundle
    for other in {app_for(k)[1] for k in BUILDS if os.path.exists(os.path.join(APPS, k)) or k == "new"} - {bundle}:
        sim.terminate(other)
    subprocess.run(["xcrun", "simctl", "install", sim.udid, app], check=True, capture_output=True)
    sim.launch(bundle)
    i, _ = sim.wait_any([dict(label="Continue with email", kind="Button"), dict(label="Workspaces", kind="RadioButton"),
                         dict(contains="Connect your Mac"), dict(ident="setup.teams.choose"), dict(ident="setup.teams.create")],
                        timeout=40)
    if i == 0:
        log(f"{build}: signing in (first run of {bundle})")
        j.s_sign_in()
    import rigsetup
    i, _ = sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                         dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton"),
                         dict(contains="Choose a space")], timeout=30)
    if i in (0, 1, 4):
        # Old builds: "Choose a space" lists Personal as a row with no identifier.
        p = (sim.find(ident="setup.teams.personal") or sim.find(label="Not now", kind="Button")
             or [e for e in sim.find(contains="Personal") if e.frame[1] > 100])
        sim.tap_el(p[0])
        sim.wait_any([dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=20)
    if sim.find(contains="Connect your Mac"):
        sim.wait(ident="connect-mac.status", timeout=30)
        rigsetup.continue_probe(sim)
    if sim.wait(label="Turn on notifications", timeout=3):
        sim.tap_q(label="Not now", kind="Button")
    st = load()
    j.seed, j.ws_name, j.device_id = st["seed"], st["ws_name"], st["device_id"]
    if not sim.find(ident="terminal.composer.field"):
        try:
            j.s_mac_discovered()
        except Exception as e:  # already linked to the rig Mac: the list shows it
            log(f"mac_discovered: {e}")
        j.open_seed_workspace()
    open_tab(sim, "e2e-t1")
    return sim, mac, j, bundle


def open_tab(sim, prefix):
    if not sim.find(label="Tabs", kind="Button"):
        return
    sim.tap_q(label="Tabs", kind="Button"); time.sleep(2.5)
    c = [e for e in sim.find(kind="Button") if (e.label or "").startswith(prefix)]
    if c:
        sim.tap_el(c[0]); time.sleep(3)


def stage_fixtures():
    src = os.path.join(HERE, "fixtures")
    dest = os.path.expanduser("~/tqf/") if tq.HOST == "local" else f"{tq.HOST}:tqf/"
    subprocess.run(["rsync", "-a", src + "/", dest], check=True)


CODEX_PROMPT = "Print the numbers 1 to {n}, one per line, each followed by a short sentence. No tools."
CODEX_DIR = os.environ.get("TQ_CODEX_DIR", "~/cmux-next-ios-e2e/tq10/proj")


def wait_mac(pred, timeout, every=1.5):
    """Polls the Mac's screen of the tab (read for timing only; every input is typed on the phone)."""
    t_end = time.time() + timeout
    while time.time() < t_end:
        try:
            text = tq.mac_screen()
        except Exception:
            text = ""
        if pred(text):
            return text
        time.sleep(every)
    return None


def codex_working(text):
    return "esc to interrupt" in text or "Working" in text


def leave_codex(j):
    """A Codex left running in the tab by an earlier run: stop it from the phone's key
    bar (Control C twice) so the next command reaches the shell."""
    try:
        text = tq.mac_screen()
    except Exception:
        return
    if "OpenAI Codex" not in text and "Ask Codex" not in text and not codex_working(text):
        return
    if not j.sim.find(label="Control C", kind="Button"):
        f = j.sim.find(ident="terminal.composer.field")
        if f:
            j.sim.tap_el(f[0]); time.sleep(1.2)
    for _ in range(3):
        j.keybar("Control C"); time.sleep(0.4)
        j.keybar("Control C"); time.sleep(2)
        if wait_mac(lambda t: "Ask Codex" not in t.splitlines()[-1] if t.strip() else True, 6) and \
                "esc to interrupt" not in tq.mac_screen():
            break


def start_agent(j, agent, args, phase="streaming", count=400):
    """Typed on the phone (composer paste + Send). Real Codex: phase "streaming"
    returns once its answer rows are arriving, "idle" once it is back at its prompt
    with the answer on screen (the Mac's screen is read for timing only)."""
    leave_codex(j)
    if agent == "codexlike":
        tq.paste_composer("clear; python3 ~/tqf/codexlike.py " + " ".join(str(a) for a in args))
    else:
        tq.paste_composer(f"clear; mkdir -p {CODEX_DIR} && cd {CODEX_DIR} && codex --yolo")
        if not wait_mac(lambda t: "Ask Codex" in t or "›" in t, 60):
            raise RuntimeError("codex prompt never showed")
        time.sleep(1)
        tq.paste_composer(CODEX_PROMPT.format(n=count))
        # This Codex shows no working indicator on screen; its state is read from the
        # answer itself: rows arriving (streaming), or "Worked for" / row 400 with the
        # screen unchanged across two reads 3 s apart (idle).
        prev = [None]

        def numbered(t):
            return sum(bool(re.match(r"\s*\d{1,4}\b", l)) for l in t.splitlines())

        if phase == "streaming":
            def streaming(t):
                moving = prev[0] is not None and t != prev[0]
                prev[0] = t
                return moving and numbered(t) >= 8
            if not wait_mac(streaming, 300):
                raise RuntimeError("codex never streamed its answer")
        else:
            def idle(t):
                same = prev[0] == t
                prev[0] = t
                finished = "Worked for" in t or re.search(r"(?m)^\s*%d\b" % count, t) is not None
                return same and finished
            if not wait_mac(idle, 900, every=3):
                raise RuntimeError("codex never finished its answer")
    time.sleep(1)
    touch("key")


def hands_off(sim, seconds, watch_jump=False):
    """Waits with no touch; optionally polls the Jump to bottom button (T-REG-1337-d)."""
    seen, t_end = [], time.time() + seconds
    while time.time() < t_end:
        if watch_jump:
            shown = bool(sim.find(label="Jump to bottom"))
            if not seen or seen[-1][1] != shown:
                seen.append((round(time.time(), 2), shown))
            time.sleep(0.2)
        else:
            time.sleep(min(0.5, t_end - time.time()))
    return seen


def analyse(video, t0, name):
    tlog = os.path.join(tq.RAW, f"{name}-touch.jsonl")
    with open(tlog, "w") as f:
        for t in TOUCH:
            f.write(json.dumps(t) + "\n")
    out = os.path.join(tq.RAW, f"{name}-motion.json")
    r = subprocess.run([sys.executable, os.path.join(HERE, "motion.py"), video, "--fps", "60", "--bottom", "0.8", "--quiet",
                        "--json", out, "--touch", tlog, "--video-start", str(t0)], capture_output=True, text=True)
    if r.returncode or not os.path.exists(out):
        raise RuntimeError(f"motion.py failed: {r.stderr[-400:]}")
    return json.load(open(out))


def window(m, t0, a, b):
    """Frames and counts between epochs a and b (video time = epoch - t0)."""
    lo, hi = a - t0, b - t0
    fr = [f for f in m["frames"] if lo <= f["t"] <= hi]
    black = [f["t"] for f in fr if f.get("black")]
    flashes = [f["t"] for f in fr if f.get("flash")]
    spont = [f for f in fr if f.get("move") and not f.get("finger")]
    rev = [b2["t"] for a2, b2 in zip(spont, spont[1:])
           if b2["t"] - a2["t"] <= 0.5 and (a2.get("shift_rows") or 0) * (b2.get("shift_rows") or 0) < 0]
    big_down = [f["t"] for f in spont if (f.get("shift_rows") or 0) > 1]  # positive: content moves down
    return {"frames": len(fr), "black": len(black), "black_at": black[:10], "flashes": len(flashes), "flash_at": flashes[:10],
            "spont_moves": len(spont), "spont_reversals": len(rev), "reversal_at": rev[:10],
            "spont_down_gt1": len(big_down), "down_at": big_down[:10]}


# ------------------------------------------------------------------ scenarios
def s1337(sim, mac, j, agent, name):
    """Codex idle at its prompt, page at and near the bottom, keyboard down, no touch."""
    start_agent(j, agent, [6, 20, 45, 3], phase="idle")
    j.hide_keyboard()
    touch("key")
    time.sleep(8)  # the working part ends; the agent idles and redraws its live area
    video = tq.rec_start(name)
    t0 = load()["rec"]["t0"]
    a = time.time()
    jump_bottom = hands_off(sim, 12, watch_jump=True)  # following at the bottom
    b = time.time()
    sim.drag(201, 380, 201, 440, 0.35, 15, 0.05)  # 4 rows up: near the bottom
    touch("drag", 0.4)
    time.sleep(1.2)
    c = time.time()
    jump_near = hands_off(sim, 12, watch_jump=True)
    d = time.time()
    tq.rec_stop()
    m = analyse(video, t0, name)
    at_bottom, near = window(m, t0, a + 0.3, b), window(m, t0, c, d)
    toggles = max(0, len(jump_bottom) - 1)
    rows = {
        "T-REG-1337-a": {"red": at_bottom["spont_reversals"] + near["spont_reversals"] > 0,
                         "evidence": {"bottom": at_bottom, "near": near}},
        "T-REG-1337-b": {"red": at_bottom["flashes"] + near["flashes"] > 0},
        "T-REG-1337-c": {"red": near["spont_down_gt1"] + at_bottom["spont_down_gt1"] > 0,
                         "note": "a jump of more than a row with no finger (a region other than the bottom)"},
        "T-REG-1337-d": {"red": toggles > 0, "evidence": {"at_bottom": jump_bottom, "near": jump_near}},
        "T-REG-1337-e": {"red": near["spont_moves"] + at_bottom["spont_moves"] > 2 * (near["frames"] + at_bottom["frames"]) / 60,
                         "note": "continuous moves with no finger (more than 2 per second on average)"},
    }
    return rows, video


def s1259(sim, mac, j, agent, name):
    """Following a working agent (keyboard down, then up), scrolling history while it
    streams, then a long fling to the top and back."""
    start_agent(j, agent, [70, 15, 5, 2], count=1500)
    j.hide_keyboard()
    touch("key")
    time.sleep(3)
    video = tq.rec_start(name)
    t0 = load()["rec"]["t0"]
    seg = {}
    a = time.time(); hands_off(sim, 15); seg["down"] = (a, time.time())
    f = sim.find(ident="terminal.composer.field")
    if f:
        sim.tap_el(f[0]); touch("tap")
    time.sleep(1.5)
    a = time.time(); hands_off(sim, 12); seg["up"] = (a, time.time())
    j.hide_keyboard(); touch("key"); time.sleep(1.5)
    a = time.time()
    for _ in range(4):
        sim.drag(201, 300, 201, 520, 0.5, 20, 0.05); touch("drag", 0.6); time.sleep(1.6)
    seg["scroll"] = (a, time.time())
    a = time.time()
    for _ in range(5):
        sim.swipe(201, 250, 201, 750, 0.12); touch("swipe", 0.2); time.sleep(0.35)
    time.sleep(2.5)
    for _ in range(6):
        sim.swipe(201, 750, 201, 250, 0.12); touch("swipe", 0.2); time.sleep(0.35)
    time.sleep(3)
    seg["fling"] = (a, time.time())
    tq.rec_stop()
    try:
        end_screen = tq.mac_screen()
    except Exception:
        end_screen = ""
    streamed_through = "Worked for" not in end_screen
    m = analyse(video, t0, name)
    w = {k: window(m, t0, *v) for k, v in seg.items()}
    rows = {
        "T-REG-1259-a": {"red": w["down"]["black"] > 0, "evidence": w["down"]},
        "T-REG-1259-b": {"red": w["up"]["black"] > 0 or w["up"]["spont_down_gt1"] > 0 or w["up"]["spont_reversals"] > 0,
                         "evidence": w["up"]},
        "T-REG-1259-c": {"red": w["scroll"]["flashes"] > 0, "evidence": w["scroll"]},
        "T-REG-1259-d": {"red": w["fling"]["black"] > 0, "evidence": w["fling"]},
        "T-REG-1259-e": {"red": sum(x["black"] for x in w.values()) > 0, "note": "any black frame in the run",
                         "evidence": {"agent_still_streaming_at_end": streamed_through}},
        "T-REG-1259-f": {"red": None, "note": "excluded: the run logs every touch (M-TOUCH); spontaneous reversals are in a/b",
                         "evidence": {k: v["spont_reversals"] for k, v in w.items()}},
    }
    return rows, video


def s1350(sim, mac, j, agent, name):
    """The grid card of a working agent shows its live bottom; a refused + -> New Claude
    Chat adds no card and changes no label."""
    start_agent(j, agent, [40, 10, 30, 2], phase="idle")
    j.hide_keyboard()
    touch("key")
    time.sleep(10)
    video = tq.rec_start(name)
    t0 = load()["rec"]["t0"]
    sim.tap_q(label="Tabs", kind="Button"); touch("tap")
    time.sleep(2.5)
    shot = tq.shot(f"{name}-grid")
    texts = [t for x, y, w, h, t in sim.ocr()]
    # The card's text is small: OCR often loses the "A" under the cursor block.
    prompt = any(k in t for t in texts for k in ("Ask Codex", "Codex to do", "context left", "Worked for"))
    rows_seen = [t for t in texts if t.startswith("#00")]
    cards0 = sorted(e.label for e in sim.find(kind="Button") if (e.label or "").startswith("e2e-"))
    # + -> New Claude Chat (refused by the Mac's cwd policy).
    # The grid bar's (+) is a pop-up "New": "New Claude Chat" (old builds) or
    # "New Agent Chat With…" -> Claude (newer builds).
    labels, menu, menu_labels = [], None, []
    menu = open_claude_item(sim, menu_labels)
    if menu:
        if menu != "refused":
            sim.tap_el(menu); touch("tap")
        t_end = time.time() + 4
        while time.time() < t_end:
            labels.append((round(time.time() - t0, 2), sorted(e.label for e in sim.find(kind="Button")
                                                               if e.frame[1] > 60 and e.frame[3] > 100)))
    else:
        log(f"1350-b: no Claude item; labels seen: {menu_labels[:40]}")
    tq.rec_stop()
    phantom = [l for l in labels if len(l[1]) > len(cards0)]
    rows = {
        "T-REG-1350-a": {"red": not prompt, "evidence": {"shot": shot, "prompt_in_card": prompt, "history_rows": rows_seen[:5]}},
        "T-REG-1350-b": {"red": (bool(phantom) if menu else None),
                         "evidence": {"cards": cards0, "menu": bool(menu), "menu_labels": menu_labels[:40],
                                      "phantom": phantom[:5], "samples": len(labels)}},
        "T-REG-1350-c": {"red": None, "note": "toast placement: read the recording (not automated)"},
    }
    return rows, video


def open_claude_item(sim, seen):
    """The grid bar's (+) -> the Claude item. Old builds: a pop-up "New" with "New
    Claude Chat"; newer: "New Agent Chat With…" -> Claude. The (+) is found by
    label "New" (any kind) or "Add"/"plus", and the menu's items by substring,
    since UIMenu items reach the AX tree as buttons or cells. Every label seen is
    kept in `seen` for the verdict's evidence."""
    def labels():
        out = sorted({(e.label or "") for e in sim.find() if e.label})
        seen[:] = out
        return out
    plus = (sim.find(label="New", kind="PopUpButton") or sim.find(label="New", kind="Button") or sim.find(label="New")
            or sim.find(label="Add", kind="Button") or sim.find(contains="plus"))
    if not plus:
        labels()
        return None
    for attempt in range(2):
        sim.tap_el(plus[0]); touch("tap")
        t_end = time.time() + 5
        while time.time() < t_end:
            ls = labels()
            claude = [l for l in ls if "Claude" in l and "Codex" not in l]
            agent = [l for l in ls if "Agent Chat" in l]
            if claude:
                return sim.find(label=claude[0])[0]
            refusal = [l for l in ls if "allow agent chats" in l or "Can't start" in l]
            if refusal:
                # This build's (+) "New" starts the agent chat at once; the Mac refused it.
                return "refused"
            if agent:
                sim.tap_el(sim.find(label=agent[0])[0]); touch("tap")
                el = sim.wait(contains="Claude", timeout=4)
                labels()
                return el
            time.sleep(0.3)
    return None


SCENARIOS = {"1259": s1259, "1337": s1337, "1350": s1350}


def run(scenario, build, agent):
    TOUCH.clear()
    if agent == "codexlike":
        stage_fixtures()
    sim, mac, j, bundle = install(build)
    name = f"reg-{scenario}-{build}-{time.strftime('%H%M%S')}"
    rows, video = SCENARIOS[scenario](sim, mac, j, agent, name)
    res = {"scenario": scenario, "build": build, "sha": BUILDS[build]["sha"] or subprocess.run(
        ["git", "-C", HERE, "rev-parse", "--short=10", "HEAD"], capture_output=True, text=True).stdout.strip(),
        "bundle": bundle, "agent": agent, "video": video, "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "load": tq.load_avg(), "rows": rows,
        "red": any(r["red"] for r in rows.values() if r["red"] is not None)}
    os.makedirs(os.path.join(OUT, scenario), exist_ok=True)
    path = os.path.join(OUT, scenario, f"{build}-{time.strftime('%m%d-%H%M%S')}.json")
    json.dump(res, open(path, "w"), indent=1, default=str)
    log(f"{scenario} on {build}: {'RED' if res['red'] else 'green'} -> {path}")
    return res


def both(scenario, old, new, agent):
    r_old, r_new = run(scenario, old, agent), run(scenario, new, agent)
    verdict = {}
    for k in r_old["rows"]:
        o, n = r_old["rows"][k]["red"], r_new["rows"].get(k, {}).get("red")
        verdict[k] = ("pass (red on old, green on new)" if o and n is False else
                      "not reproduced (green on old)" if o is False else
                      "FAIL (red on new)" if n else "not decided")
    res = {"scenario": scenario, "old": old, "new": new, "agent": agent, "rows": verdict}
    path = os.path.join(OUT, scenario, f"compare-{old}-{new}-{time.strftime('%m%d-%H%M%S')}.json")
    json.dump(res, open(path, "w"), indent=1)
    print(json.dumps(res, indent=1))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    agent = sys.argv[sys.argv.index("--agent") + 1] if "--agent" in sys.argv else "codexlike"
    args = [a for a in args if a != agent]
    cmd = args[0]
    if cmd == "builds":
        for k in BUILDS:
            print(k, *app_for(k))
    elif cmd == "run":
        print(json.dumps(run(args[1], args[2], agent), indent=1, default=str))
    elif cmd == "both":
        both(args[1], args[2], args[3] if len(args) > 3 else "new", agent)


if __name__ == "__main__":
    main()
