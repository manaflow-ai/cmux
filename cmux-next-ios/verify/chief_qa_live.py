#!/usr/bin/env python3
"""Chief QA over the real link: several Chiefs, both directions, long history, offline.

Runs ON a cmux mini: the hidden rig Mac (mac.py) and the iOS app in one headless
simulator driven with AXe, as chief_delete_live.py does.

    python3 chief_qa_live.py --mac-app PATH --app PATH [--sim-name cmux-chiefqa] [--out DIR]
                             [--only a,b,...] [--long 200]

Scenarios (each records pass/fail and goes on):
- home_lists:   two new Chiefs made on the Mac show on the phone's Home.
- mac_to_phone: messages the Mac writes in a Chief's conversation reach the open
                conversation on the phone, in order, once.
- phone_to_mac: a message typed on the phone reaches the Mac's conversation once.
- no_crosstalk: the other Chief's conversation shows none of the first's messages.
- long_history: the Mac writes N messages in a row; the phone shows the newest, in
                order; the app's memory is read before and after.
- offline:      the phone app is not running while the Mac writes; on relaunch the
                conversation has them all, once.
- mac_quit:     the Mac app quits; a message sent on the phone to the Mac Chief waits,
                then reaches the Mac once when it is back.
- delete_open:  the Mac deletes the Chief whose conversation is open on the phone.
- appearance:   Home and a conversation in light, dark, and the largest text size.
Writes DIR/results.json, run.log, shots/, phone.mp4.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from e2e import CNX, RUNTIMES, ensure_sim  # noqa: E402
import journey  # noqa: E402
from journey import Journey  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402
from chief_delete_live import debug, mac_shot, phone_titles, shows, wait_for  # noqa: E402

ALL = ["home_lists", "mac_to_phone", "phone_to_mac", "no_crosstalk", "long_history", "offline",
       "mac_quit", "delete_open", "appearance"]


def records(value):
    if isinstance(value, dict):
        if "id" in value and ("display_name" in value or "title" in value):
            yield value
        for v in value.values():
            yield from records(v)
    elif isinstance(value, list):
        for v in value:
            yield from records(v)


def app_rss_mb(bundle_exe="CmuxMobileApp"):
    """Resident memory of the simulator app (it runs as a host process)."""
    out = subprocess.run(["ps", "-axo", "rss=,comm="], capture_output=True, text=True).stdout
    sizes = [int(line.split()[0]) for line in out.splitlines() if line.strip().endswith("/" + bundle_exe)]
    return round(max(sizes) / 1024, 1) if sizes else None


def main():  # noqa: C901 - one live run of several scenarios
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--sim-name", default="cmux-chiefqa")
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--out")
    ap.add_argument("--only", default=",".join(ALL))
    ap.add_argument("--long", type=int, default=200)
    a = ap.parse_args()
    only = [s for s in a.only.split(",") if s]

    mac_app = os.path.abspath(a.mac_app)
    journey.BUNDLE = pb(os.path.join(a.app, "Info.plist"), "Print :CFBundleIdentifier")
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "chief-qa")
    shots = os.path.join(out, "shots")
    os.makedirs(shots, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app, cleanup=True, log=log).prepare()
    mac.seed_pairing(names=[a.sim_name])
    udid = ensure_sim(a.sim_name, RUNTIMES[a.ios], log)
    sim = Sim(udid, shots)
    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], capture_output=True)
    subprocess.run(["xcrun", "simctl", "ui", udid, "content_size", "large"], capture_output=True)
    result = {"mac_app": os.path.basename(mac_app), "app": a.app, "simulator": f"{a.sim_name} {udid}",
              "scenarios": {}, "shots": {}}
    S = result["scenarios"]
    n_shot = [0]

    def shot(name):
        n_shot[0] += 1
        path = sim.shot(f"{n_shot[0]:02d}-{name}")
        result["shots"][name] = path
        return path

    def chief_socket():
        """The rig Mac's Chief session daemon socket (its `cmux-tui --session cmux-chief-*`)."""
        out = subprocess.run(["ps", "-axww", "-o", "args="], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if os.path.dirname(mac.cli) in line and "--session cmux-chief-" in line and "--socket " in line:
                return line.split("--socket ", 1)[1].split(" --", 1)[0].strip()
        return None

    def conv_cli(*args, timeout=60):
        """`cmux-tui conversation ...` on the Chief session (the app's `cmux` hides that scope)."""
        sock = chief_socket()
        if not sock:
            raise RuntimeError("no Chief session daemon for the rig Mac")
        r = subprocess.run([os.path.join(os.path.dirname(mac.cli), "cmux-tui"), "--socket", sock, "--json", "conversation", *args],
                           capture_output=True, text=True, timeout=timeout)
        if r.returncode != 0:
            raise RuntimeError(f"conversation {' '.join(args)}: {(r.stderr or r.stdout).strip()[:300]}")
        out = r.stdout.strip()
        try:
            return json.loads(out) if out else None
        except ValueError:
            return [json.loads(x) for x in out.splitlines() if x.strip()]

    def conv_messages(conv, tail=200):
        value = conv_cli(conv, "get", "--tail", str(tail)) or {}
        found = []

        def walk(v):
            if isinstance(v, dict):
                if "seq" in v and "parts" in v:
                    found.append(v)
                else:
                    for x in v.values():
                        walk(x)
            elif isinstance(v, list):
                for x in v:
                    walk(x)
        walk(value)
        return found

    def texts_of(messages):
        return ["".join(p.get("text", "") for p in m.get("parts", []) if isinstance(p, dict)) for m in messages]

    def mac_send(conv, text):
        conv_cli(conv, "send", "--text", text, timeout=30)

    def phone_texts():
        """Every label on screen; a bubble reads "Your message, <text>, <time>" (mine)."""
        out = []
        for e in sim.tree():
            label = e.label or ""
            if label.startswith("Your message, "):
                label = label[len("Your message, "):].rsplit(", ", 1)[0]
            if label:
                out.append(label)
        return out

    def bubbles(prefix):
        """Distinct message bubbles starting with `prefix`, by text and position."""
        seen = {}
        for e in sim.tree():
            label = e.label or ""
            if label.startswith("Your message, "):
                label = label[len("Your message, "):].rsplit(", ", 1)[0]
            if label.startswith(prefix):
                seen[(label, round(e.frame[1] / 8))] = label
        return list(seen.values())

    def phone_has(needle):
        return any(needle in t for t in phone_texts())

    def open_row(name, timeout=30):
        j.tab("Home")
        ok, _ = wait_for(lambda: shows(sim, name), timeout)
        if not ok:
            raise RuntimeError(f"Home never listed {name!r}: {phone_titles(sim)}")
        rows = [e for e in sim.tree() if e.ident and e.ident.startswith(("home.row.", "home.pin.")) and name in (e.label or "")]
        sim.tap_el(rows[0])
        ok, _ = wait_for(lambda: sim.find(ident="conversation.composer.text"), 30)
        if not ok:
            raise RuntimeError(f"{name!r} conversation never showed its composer")
        time.sleep(1.0)

    def back_home():
        for _ in range(4):
            if sim.find(ident="home.compose"):
                return
            sim.drag(3, 400, 300, 400, 0.35, 25, 0.05)
            time.sleep(0.8)
        j.tab("Home")

    def phone_send(text):
        field = sim.wait(ident="conversation.composer.text", timeout=15)
        if not field:
            raise RuntimeError("no composer")
        sim.tap_el(field)
        time.sleep(0.5)
        # Hardware key events type plain text reliably (the soft keyboard's
        # layout switch lags on a loaded mini).
        subprocess.run(["axe", "type", text, "--udid", udid], capture_output=True, timeout=60)
        time.sleep(0.3)
        send = sim.wait(ident="conversation.composer.send", timeout=5)
        if not send:
            # Found live (base and fix alike): the first tap on the composer after
            # opening a conversation does not focus it; the second does.
            result.setdefault("observations", []).append("first composer tap did not focus; tapped again")
            sim.tap_el(field)
            time.sleep(1.0)
            subprocess.run(["axe", "type", text, "--udid", udid], capture_output=True, timeout=60)
            send = sim.wait(ident="conversation.composer.send", timeout=10)
        if not send:
            now = sim.find(ident="conversation.composer.text")
            focus = [(e.kind, e.ident) for e in sim.tree() if e.get("AXFocused") or e.get("focused")]
            shot("typing-did-not-land")
            raise RuntimeError(f"no Send button; composer {now[0].value if now else None!r}, focused {focus[:3]}")
        sim.tap_el(send)

    def scenario(name, fn):
        if name not in only:
            return
        log(f"== {name}")
        t0 = time.time()
        try:
            r = fn() or {}
            r.setdefault("pass", True)
        except Exception as e:  # noqa: BLE001 - a scenario's failure is its result
            r = {"pass": False, "error": f"{type(e).__name__}: {e}", "trace": traceback.format_exc()[-1500:]}
            try:
                shot(f"{name}-error")
            except Exception:  # noqa: BLE001
                pass
        r["seconds"] = round(time.time() - t0, 1)
        S[name] = r
        log(f"   {name}: {'PASS' if r.get('pass') else 'FAIL'} {json.dumps({k: v for k, v in r.items() if k != 'trace'})[:600]}")

    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}), host {'running' if mac.wait_hostd(180) else 'NOT running'}")
        for old in list(records(mac.cmux("chief", "list", json_out=True))):
            if str(old.get("display_name", "")).startswith("QA "):
                mac.cmux("chief", "delete", old["id"], check=False)
        run_id = time.strftime("%H%M")
        names = {"alpha": f"QA Alpha {run_id}", "beta": f"QA Beta {run_id}"}
        chiefs = {}
        for role, name in names.items():
            value = mac.cmux("chief", "new", "--name", name, json_out=True) or {}
            chiefs[role] = (value.get("value") or value).get("id")
        convs = {}
        conversations = []
        for _ in range(30):
            listed = None
            try:
                listed = conv_cli("list")
            except RuntimeError as e:
                log(f"conversation list: {e}")
            # Conversations (with participants), not the participant records inside them.
            conversations = [c for c in records(listed) if isinstance(c.get("participants"), list)]
            convs = {}
            for c in conversations:
                ids = [p.get("id") for p in c["participants"] if isinstance(p, dict)]
                for role, chief in chiefs.items():
                    if (chief in ids and len(ids) == 2) or (role not in convs and c.get("title") == names[role]):
                        convs[role] = c["id"]
            if len(convs) == 2:
                break
            # A new Chief's conversation shows up a moment after `chief new`.
            time.sleep(2)
        result["conversation_titles"] = {c["id"]: c.get("title") for c in conversations}
        result.update(names=names, chiefs=chiefs, conversations=convs)
        log(f"Chiefs {chiefs}, conversations {convs}")
        main_conv = next((c["id"] for c in conversations
                          if any(p.get("id") == "agent_mux" for p in c["participants"] if isinstance(p, dict))), None)
        if len(convs) != 2:
            raise RuntimeError(f"Chief conversations not found: {convs}; listed {result['conversation_titles']}")
        result["main_conversation"] = main_conv

        global j
        j = Journey(sim, mac, out, a.app, log)
        steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        if any(st["status"] != "pass" for st in steps):
            log("setup failed once; relaunching and retrying")
            sim.launch(journey.BUNDLE)
            steps = j.run(only={"choose_space", "mac_discovered"})[-2:]
        log(f"setup: {[(s['id'], s['status']) for s in steps]}")
        if any(st["status"] != "pass" for st in steps):
            raise RuntimeError(f"setup failed: {steps}")
        debug(mac, "action.run", {"action": "home.show", "origin": "script"})
        sim.record_start(os.path.join(out, "phone.mp4"))

        def home_lists():
            j.tab("Home")
            ok, secs = wait_for(lambda: shows(sim, names["alpha"]) and shows(sim, names["beta"]), 90)
            shot("home-two-chiefs")
            mac_shot(mac, os.path.join(shots, "mac-home.png"))
            return {"pass": bool(ok), "seconds_to_list": secs, "rows": phone_titles(sim)}
        scenario("home_lists", home_lists)

        def mac_to_phone():
            open_row(names["alpha"])
            sent = [f"mac to phone {i} {run_id}" for i in range(1, 4)]
            t0 = time.time()
            for text in sent:
                mac_send(convs["alpha"], text)
            ok, _ = wait_for(lambda: all(phone_has(t) for t in sent), 30)
            latency = round(time.time() - t0, 2)
            shot("alpha-mac-to-phone")
            labels = sorted(set(t for t in bubbles("mac to phone") if run_id in t))
            order = [next(i for i, s in enumerate(sent) if s in t) for t in labels if any(s in t for s in sent)]
            # Each bubble carries its text on two elements (the cell and its text).
            raw = [t for t in phone_texts() if t.startswith("mac to phone") and run_id in t]
            dup = any(raw.count(t) > 2 for t in labels)
            return {"pass": bool(ok) and order == sorted(order) and not dup, "seconds_all_shown": latency,
                    "labels": labels[:8], "duplicates": dup}
        scenario("mac_to_phone", mac_to_phone)

        def phone_to_mac():
            if not sim.find(ident="conversation.composer.text"):
                open_row(names["alpha"])
            text = f"phone to mac {run_id}"
            t0 = time.time()
            phone_send(text)
            # iOS capitalizes the first letter as it is typed.
            def copies():
                return [t.lower() for t in texts_of(conv_messages(convs["alpha"]))].count(text)
            ok, _ = wait_for(lambda: copies() >= 1, 30)
            secs = round(time.time() - t0, 2)
            time.sleep(3)
            count = copies()
            shot("alpha-phone-to-mac")
            return {"pass": bool(ok) and count == 1, "seconds_on_mac": secs, "copies_on_mac": count}
        scenario("phone_to_mac", phone_to_mac)

        def no_crosstalk():
            back_home()
            open_row(names["beta"])
            leaked = [t for t in phone_texts() if run_id in t and ("mac to phone" in t or "phone to mac" in t)]
            shot("beta-no-crosstalk")
            return {"pass": not leaked, "leaked": leaked}
        scenario("no_crosstalk", no_crosstalk)

        def long_history():
            if not sim.find(ident="conversation.composer.text"):
                open_row(names["beta"])
            before = app_rss_mb()
            t0 = time.time()
            for i in range(1, a.long + 1):
                mac_send(convs["beta"], f"long {i:03d} {run_id} " + ("lorem ipsum dolor " * (i % 7)))
            wrote = round(time.time() - t0, 1)
            last = f"long {a.long:03d} {run_id}"
            ok, secs = wait_for(lambda: phone_has(last), 60)
            shot("beta-long-newest")
            on_mac = [t for t in texts_of(conv_messages(convs["beta"], 500)) if t.startswith("long ")]
            visible = sorted(set(t for t in phone_texts() if t.startswith("long ") and run_id in t))
            nums = [int(t.split()[1]) for t in visible]
            # Scroll to the top through the whole history.
            for _ in range(12):
                sim.drag(200, 250, 200, 750, 0.25, 15, 0.02)
            time.sleep(1.5)
            shot("beta-long-scrolled-up")
            after = app_rss_mb()
            return {"pass": bool(ok) and nums == sorted(nums) and len(set(nums)) == len(nums) and len(on_mac) == a.long,
                    "mac_wrote_s": wrote, "newest_on_phone_s": secs, "visible_numbers": nums,
                    "on_mac": len(on_mac), "rss_mb_before": before, "rss_mb_after": after}
        scenario("long_history", long_history)

        def offline():
            sim.terminate(journey.BUNDLE)
            time.sleep(2)
            sent = [f"while phone off {i} {run_id}" for i in range(1, 31)]
            for text in sent:
                mac_send(convs["alpha"], text)
            sim.launch(journey.BUNDLE)
            time.sleep(3)
            open_row(names["alpha"], timeout=90)
            ok, secs = wait_for(lambda: phone_has(sent[-1]), 60)
            shot("alpha-after-offline")
            raw = [t for t in phone_texts() if t.startswith("while phone off") and run_id in t]
            visible = sorted(set(raw), key=lambda t: int(t.split()[3]))
            dup = any(raw.count(t) > 2 for t in visible)
            nums = [int(t.split()[3]) for t in visible]
            return {"pass": bool(ok) and not dup and nums == sorted(nums), "newest_shown_s": secs,
                    "visible": nums, "duplicates": dup}
        scenario("offline", offline)

        def mac_quit():
            if not main_conv:
                raise RuntimeError("no main Chief conversation on the Mac")
            back_home()
            j.tab("Home")
            pin = sim.wait(ident="home.chief.mac", timeout=20) or sim.wait(prefix="home.pin.", timeout=5)
            if not pin:
                raise RuntimeError("no Mac Chief pin on Home")
            sim.tap_el(pin)
            if not sim.wait(ident="conversation.composer.text", timeout=30):
                raise RuntimeError("Mac Chief conversation never opened")
            mac.quit()
            text = f"sent while mac away {run_id}"
            try:
                # Quit returns before the phone hears of it: wait until the conversation says so.
                wait_for(lambda: any("Connecting" in t or "isn't connected" in t or "away" in t.lower()
                                     for t in phone_texts()), 60)
                phone_send(text)
                time.sleep(3)
                shot("mac-chief-mac-away")
                phone_view = [t for t in phone_texts() if "Waiting" in t or "Not Delivered" in t or "away" in t.lower()
                              or "isn't connected" in t]
                # The phone holds the message and asks: keep it for when Chief connects.
                later = sim.wait(label="Send When Chief Connects", timeout=10)
                if later:
                    sim.tap_el(later)
                    time.sleep(2)
                    shot("mac-chief-waiting-to-send")
                    phone_view += [t for t in phone_texts() if "Waiting" in t][:3]
            finally:
                # The Mac comes back whatever happened on the phone (later scenarios need it).
                mac.launch()
                mac.wait_hostd(180)
            def copies():
                return [t.lower() for t in texts_of(conv_messages(main_conv))].count(text)
            ok, secs = wait_for(lambda: copies() >= 1, 120)
            time.sleep(4)
            count = copies()
            shot("mac-chief-mac-back")
            return {"pass": bool(ok) and count == 1, "delivered_after_relaunch_s": secs, "copies_on_mac": count,
                    "phone_said_while_away": phone_view[:5]}
        scenario("mac_quit", mac_quit)

        def delete_open():
            back_home()
            open_row(names["beta"], timeout=60)
            # The Mac's own action, else its CLI (action.run refuses with "not_run"
            # when the Mac's main thread is busy on a loaded mini).
            run = debug(mac, "action.run", {"action": "home.deleteChief", "origin": "script",
                                            "args": {"chief": chiefs["beta"], "confirm": True}}, timeout=30)
            if run.get("ok") is not True:
                log(f"   action.run refused ({json.dumps(run)[:200]}); deleting with the CLI")
                cli = mac.cmux("chief", "delete", chiefs["beta"], check=False, timeout=60)
                run = {"ok": cli.returncode == 0, "via": "cli"}
            time.sleep(6)
            shot("beta-deleted-while-open")
            still_open = bool(sim.find(ident="conversation.composer.text"))
            texts = [t for t in phone_texts() if t][:20]
            back_home()
            gone, _ = wait_for(lambda: shows(sim, names["beta"]) is False, 30)
            shot("home-after-delete-open")
            # Not a hard pass/fail on what the open screen does; recorded for review.
            return {"pass": run.get("ok") is True and bool(gone), "conversation_still_open": still_open,
                    "open_screen_texts": texts}
        scenario("delete_open", delete_open)

        def appearance():
            out_shots = {}
            back_home()
            for mode, size in (("dark", "large"), ("light", "accessibility-extra-extra-extra-large"),
                               ("dark", "accessibility-extra-extra-extra-large"), ("light", "large")):
                subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", mode], capture_output=True)
                subprocess.run(["xcrun", "simctl", "ui", udid, "content_size", size], capture_output=True)
                time.sleep(2)
                j.tab("Home")
                out_shots[f"home-{mode}-{size}"] = shot(f"home-{mode}-{size}")
                try:
                    open_row(names["alpha"], timeout=30)
                    out_shots[f"conv-{mode}-{size}"] = shot(f"alpha-{mode}-{size}")
                finally:
                    back_home()
            return {"shots": out_shots}
        scenario("appearance", appearance)

        result["pass"] = all(v.get("pass") for v in S.values())
        log("ALL PASS" if result["pass"] else f"FAILED: {[k for k, v in S.items() if not v.get('pass')]}")
    finally:
        try:
            sim.record_stop()
        except Exception:  # noqa: BLE001
            pass
        try:
            mac.teardown()
        except Exception as e:  # noqa: BLE001
            log(f"teardown: {e}")
        json.dump(result, open(os.path.join(out, "results.json"), "w"), indent=2)
        log(f"wrote {out}/results.json")


if __name__ == "__main__":
    main()
