"""qa-round-11 implementer: runs the v8/v8v rig helpers with evidence redirected to
qa12/ and raw video to ~/cmux-next-ios-e2e/termqa-raw/tq12/. Select the phone build with
TQ_BUNDLE (a tagged demo build, e.g. dev.cmux.mobile.tq10).

    TQ_BUNDLE=dev.cmux.mobile.tq10 python3 q12.py v8v_drop TAG read1
    TQ_BUNDLE=dev.cmux.mobile.tq10 python3 q12.py install APP_PATH   # install, launch with -CmuxMobileFrameLog, open e2e-t2
"""
import importlib
import os
import sys

import tq
import v8

V = os.path.abspath(os.path.join(tq.HERE, "../design/terminal/qa12"))
RAW = os.path.expanduser("~/cmux-next-ios-e2e/termqa-raw/tq12")
os.makedirs(V, exist_ok=True)
os.makedirs(RAW, exist_ok=True)
v8.V6 = V
v8.RAW6 = RAW
tq.RAW = RAW

_rec_start = tq.rec_start


def _rec_start_logged(name):
    path = _rec_start(name)
    v8.ev("rec_start", name=name, path=path, t0=tq.load()["rec"]["t0"])
    return path


tq.rec_start = _rec_start_logged

# The rig's `--tap-style simulator` tap started hanging for 25 s on every call at 03:50
# (round 8); the automatic style still works. Try the rig's style briefly, then automatic.
import subprocess as _sp
import time as _time
from sim import Sim as _Sim


def _tap(self, x, y):
    t = _time.time()
    for style, to in (("simulator", 6), ("automatic", 30)):
        try:
            _sp.run(["axe", "tap", "--udid", self.udid, "-x", f"{x:.1f}", "-y", f"{y:.1f}", "--tap-style", style],
                    capture_output=True, text=True, timeout=to)
            return t
        except _sp.TimeoutExpired:
            continue
    raise RuntimeError(f"tap {x},{y} failed in both styles")


_Sim.tap = _tap

def install(app):
    """Install APP over the rig's state, launch it with the frame log, open e2e-t2."""
    import reg
    st = tq.load(); st["app_path"] = os.path.abspath(app); tq.save(st)
    sim, mac, j, bundle = reg.install("new")
    sim.launch(bundle, args=["-CmuxMobileFrameLog", "YES"])
    _time.sleep(6)
    if not sim.find(ident="terminal.composer.field"):
        j.open_seed_workspace()
    reg.open_tab(sim, "e2e-t2")
    v8.ev("install", app=app, bundle=bundle)


def transport(name, relay):
    """Settings > Transport: NAME (WebRTC|WireGuard), Relay only on|off; back in e2e-t2 when linked."""
    import reg
    sim, mac, j = tq.ctx()
    if sim.find(label="Tabs", kind="Button"):
        j.back_to_list()
    j.open_transport_page()
    kind = {"WebRTC": "webrtc", "WireGuard": "wireguard"}[name]
    sim.tap_el(sim.find(ident=f"settings.transport.{kind}")[0]); _time.sleep(1)
    box = sim.find(ident="settings.transport.relayOnly")[0]
    if (box.value == "1") != (relay == "on"):
        x, y, w, h = box.frame  # the switch at the row's right edge (a tap on the row's centre is ignored)
        sim.tap(x + w - 40, y + h / 2); _time.sleep(1.5)
    j.close_transport_page()
    j.tab("Workspaces")
    t = _time.time(); lab = ""
    while _time.time() - t < 40:
        lab = j.link_status()
        if "Connected" in lab and name.lower() in lab.lower():
            break
        _time.sleep(0.5)
    j.open_seed_workspace()
    reg.open_tab(sim, "e2e-t2")
    v8.ev("transport", name=name, relay=relay, label=lab, hostd=v8.hostd_events(t - 1))
    return lab


if __name__ == "__main__" and sys.argv[1] == "transport":
    print(transport(sys.argv[2], sys.argv[3]))
elif __name__ == "__main__" and sys.argv[1] == "install":
    install(sys.argv[2])
elif __name__ == "__main__":
    mod = importlib.import_module(sys.argv[1])
    sys.argv = [sys.argv[1] + ".py"] + sys.argv[2:]
    mod.main()
