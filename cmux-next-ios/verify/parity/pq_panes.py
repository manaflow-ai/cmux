"""Panes parity flows (feat-cmux-next-ios-panes-parity, cmux#25834 slice A Panes rows and slice C's
fork destinations): the Panes page, Split Right / Down / Left / Up, New Pane, New Column, Zoom,
Swap, Rename, Close Pane, Equalize Splits, Undo Layout Change, Move Tab to New Split / New
Column / Pane, and Fork Conversation to the right and to a new workspace.

Same rig as pq.py and pq_tabs.py: the phone app in ONE headless simulator, the real tagged
cmux-next Mac app (rmac.py), the real link between them. Every action under test is done on
the phone; after each one the Mac's layout is read back from the rig app's own daemon
(`list-workspaces` over ssh, pq_tabs.mac_raw) and recorded in the flow's result.

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    PQ_HOST=local PQ_RBASE=~/cmux-next-ios-e2e/panes PQ_TAG=<rig tag> PQ_SIM=panes-phone \\
    PQ_STATE=~/cmux-next-ios-e2e/panes/state.json PQ_RAW=~/cmux-next-ios-e2e/panes/raw \\
    python3 -c 'import pq_panes as p; print(p.run("split", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch). Workspaces are named
`p2tabs-panes-*` (pq_tabs.seed's prefix). The fork flow needs PQ_ACPMUX_SOCK (pq_chats).
"""
import json
import os
import shlex
import time

import pq
import pq_tabs as t
from journey import Fail, check


# ---------------------------------------------------------------- the Mac side (read only)

# The rig Mac's acpmux socket (as pq_chats on #26478): rig setup starts the chat the fork flow uses.
_ACPMUX = r"""
import glob, json, os, socket, sys
paths = sorted(glob.glob(os.path.expanduser(sys.argv[1])), key=os.path.getmtime)
s = socket.socket(socket.AF_UNIX); s.connect(paths[-1]); f = s.makefile("rw")
f.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1,
        "clientInfo": {"name": "pq_panes", "version": "1"}, "clientCapabilities": {}}}) + "\n")
f.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": sys.argv[2], "params": json.loads(sys.argv[3])}) + "\n"); f.flush()
while True:
    m = json.loads(f.readline())
    if m.get("id") == 2:
        print(json.dumps(m.get("result", m))); break
"""


def acpmux(method, params=None, timeout=60):
    sock = os.environ.get("PQ_ACPMUX_SOCK", "")
    check(sock, "PQ_ACPMUX_SOCK (the rig Mac's acpmux socket glob) is not set")
    r = pq.rsh(f"python3 -c {shlex.quote(_ACPMUX)} {shlex.quote(sock)} {shlex.quote(method)} "
               f"{shlex.quote(json.dumps(params or {}))}", timeout=timeout)
    check(r.returncode == 0, f"acpmux {method}: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def start_chat(folder, prompt):
    """A Claude chat on the Mac, started and answered over its local acpmux socket (rig setup)."""
    sid = acpmux("session/new", {"cwd": folder, "mcpServers": [],
                                 "_meta": {"acpmux": {"harness": "claude", "policy": "ask"}}})["sessionId"]
    acpmux("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": prompt}]}, timeout=300)
    return sid

def node_text(node):
    """`right(0.70)[1, down(0.50)[2, 3]]` for a split tree."""
    if not node:
        return "-"
    kind = node.get("type")
    if kind == "leaf":
        return str(node.get("pane"))
    if kind == "stack":
        return "stack" + str(node.get("panes"))
    return f"{node.get('dir')}({node.get('ratio', 0):.2f})[{node_text(node.get('a'))}, {node_text(node.get('b'))}]"


def mac_layout(key):
    """The workspace's shown screen on the Mac: its split tree, panes (name, tab titles),
    zoomed pane and viewport columns."""
    ws = t.mac_workspace(key=key)
    check(ws, f"workspace {key} not on the Mac")
    screens = ws.get("screens", [])
    screen = next((s for s in screens if s.get("active")), screens[0] if screens else {})
    panes = [{"id": p.get("id"), "name": p.get("name") or "",
              "tabs": [x.get("name") or x.get("title") or x.get("kind") for x in p.get("tabs", [])],
              "kinds": [x.get("kind") for x in p.get("tabs", [])]}
             for p in screen.get("panes", [])]
    return {"layout": node_text(screen.get("layout")), "panes": panes, "focused": screen.get("active_pane"),
            "zoomed": screen.get("zoomed_pane"), "columns": len(screen.get("columns") or []), "screens": len(screens)}


def wait_layout(key, test, what, timeout=20):
    """Until the Mac's layout passes `test`; returns (layout, seconds)."""
    return t.until(lambda: (lambda lay: lay if test(lay) else None)(mac_layout(key)), timeout=timeout, what=what)


def pane_of(lay, title):
    return next((p for p in lay["panes"] if title in p["tabs"]), None)


# ---------------------------------------------------------------- the phone side

def menu_labels(j):
    return [e.label for e in j.sim.find(kind="Button") if e.label]


def open_page_menu(j):
    bottom = [e for e in j.sim.find(kind="Button") if e.frame[1] > 740 and e.frame[2] > 120]
    check(bottom, "no title capsule at the bottom")
    j.sim.tap_el(bottom[0])
    time.sleep(1.2)
    return menu_labels(j)


def menu_row(j, label, timeout=5):
    """A row of an open menu, scrolled into view (a long page menu scrolls)."""
    for _ in range(6):
        row = j.sim.wait(label=label, kind="Button", timeout=timeout)
        if not row:
            return None
        x, y, w, h = row.frame
        if y + h < 820:
            return row
        j.sim.swipe(215, 700, 215, 300, 0.4)
        time.sleep(0.8)
        timeout = 2
    return None


def tap_row(j, label, timeout=5):
    row = menu_row(j, label, timeout)
    check(row, f"no {label!r}; buttons: {menu_labels(j)[:30]}")
    j.sim.tap_el(row)
    time.sleep(1.0)


def close_menu(j):
    j.sim.tap(200, 300)
    time.sleep(0.8)


def open_panes(j):
    """The page menu, then Panes (N)."""
    labels = open_page_menu(j)
    row = next((x for x in labels if x == "Panes" or x.startswith("Panes (")), None)
    check(row, f"no Panes in the page menu: {labels[:30]}")
    tap_row(j, row)
    check(j.sim.wait(ident="panes.screen", timeout=8) or j.sim.wait(label="Panes", timeout=4), "the Panes page did not open")
    time.sleep(0.8)


def toolbar(j, ident, item):
    """A Panes toolbar menu (`panes.add`, `panes.layout`), then its row `item`."""
    e = j.sim.wait(ident=ident, timeout=6)
    check(e, f"no {ident} in the Panes toolbar")
    j.sim.tap_el(e)
    time.sleep(1.0)
    tap_row(j, item)


def pane_menu(j, pane_id, item, sub=None):
    """A pane section's ⋯ menu, then `item` (and `sub` in its submenu)."""
    e = j.sim.wait(ident=f"panes.menu.{pane_id}", timeout=8)
    check(e, f"no menu for pane {pane_id}; ids: {[x.ident for x in j.sim.find() if (x.ident or '').startswith('panes.')]}")
    j.sim.tap_el(e)
    time.sleep(1.0)
    tap_row(j, item)
    if sub:
        tap_row(j, sub)


def tab_menu(j, surface, item, sub=None):
    """A long press on a tab row of the Panes page, then `item` (and `sub` in its submenu)."""
    e = j.sim.wait(ident=f"panes.tab.s{surface}", timeout=8)
    check(e, f"no tab row s{surface}")
    x, y = e.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(1.2)
    tap_row(j, item)
    if sub:
        tap_row(j, sub)


def seed(tag, terminals=1):
    ws = t.seed(f"panes-{tag}", terminals=terminals)
    return ws, ws["key"], ws.get("name") or ws.get("title")


def before_menu(j, name, shot):
    """The base app: the page menu has no Panes (the gap)."""
    t.open_ws(j, name)
    t.open_tab(j, "p2tabs-t1")
    labels = open_page_menu(j)
    pq.shot(shot)
    close_menu(j)
    return {"page_menu": labels, "has_panes": any(x.startswith("Panes") for x in labels)}


# ---------------------------------------------------------------- flows

def split(j, label):
    """Split Right (toolbar +), Split Down and Split Left (a pane's menu), New Pane and New
    Column: after each, the Mac's layout."""
    ws, key, name = seed("split")
    if label == "before":
        return dict(before_menu(j, name, "split-before-page-menu"), mac=mac_layout(key))
    out = {"start": mac_layout(key)}
    t.open_ws(j, name)
    t.open_tab(j, "p2tabs-t1")
    open_panes(j)
    pq.shot("split-after-panes-one")
    first = out["start"]["panes"][0]["id"]
    toolbar(j, "panes.add", "Split Right")
    out["split_right"], took = wait_layout(key, lambda lay: len(lay["panes"]) == 2, "Split Right on the Mac")
    out["split_right_s"] = round(took, 1)
    pq.shot("split-after-right")
    pane_menu(j, first, "Split Down")
    out["split_down"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 3, "Split Down on the Mac")
    pq.shot("split-after-down")
    pane_menu(j, first, "Split Left")
    out["split_left"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 4, "Split Left on the Mac")
    pq.shot("split-after-left")
    toolbar(j, "panes.add", "New Pane")
    out["new_pane"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 5, "New Pane on the Mac")
    toolbar(j, "panes.add", "New Column")
    out["new_column"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 6, "New Column on the Mac")
    time.sleep(1.5)
    pq.shot("split-after-columns")
    return out


def manage(j, label):
    """Zoom and Unzoom, Swap Pane Right, Rename Pane…, Equalize Splits and Close Pane on a
    workspace the Mac split 70/30 (rig setup)."""
    ws, key, name = seed("manage", terminals=1)
    pane = t.ws_tabs(ws)[0][0]
    t.mac_raw({"cmd": "split", "pane": pane, "dir": "right"})
    lay = mac_layout(key)
    split = t.mac_workspace(key=key)["screens"][0]["layout"]["split"]
    t.mac_raw({"cmd": "set-split-ratio", "split": split, "ratio": 0.7})
    right = lay["panes"][1]["id"]
    t.mac_raw({"cmd": "rename-surface", "surface": t.ws_tabs(t.mac_workspace(key=key))[1][1]["surface"], "name": "p2tabs-t2"})
    out = {"start": mac_layout(key)}
    if label == "before":
        return dict(before_menu(j, name, "manage-before-page-menu"), mac=out["start"])
    t.open_ws(j, name)
    t.open_tab(j, "p2tabs-t1")
    open_panes(j)
    pq.shot("manage-after-panes")
    pane_menu(j, pane, "Zoom Pane")
    out["zoomed"], _ = wait_layout(key, lambda lay: lay["zoomed"] == pane, "the zoom on the Mac")
    time.sleep(1)
    pq.shot("manage-after-zoomed")
    pane_menu(j, pane, "Unzoom Pane")
    out["unzoomed"], _ = wait_layout(key, lambda lay: lay["zoomed"] is None, "the unzoom on the Mac")
    pane_menu(j, pane, "Swap Pane Right")
    out["swapped"], _ = wait_layout(key, lambda lay: lay["panes"][0]["id"] == right, "the swap on the Mac")
    time.sleep(1)
    pq.shot("manage-after-swapped")
    pane_menu(j, pane, "Rename Pane…")
    field = j.sim.wait(ident="panes.rename.field", timeout=4) or j.sim.wait(kind="TextField", timeout=4)
    check(field, "no Rename Pane field")
    pq.shot("manage-after-rename-field")
    pq.type_text("build")
    time.sleep(0.5)
    tap_row(j, "Rename")
    out["renamed"], _ = wait_layout(key, lambda lay: any(p["name"] == "build" for p in lay["panes"]), "the name on the Mac")
    time.sleep(1)
    pq.shot("manage-after-renamed")
    toolbar(j, "panes.layout", "Equalize Splits")
    out["equalized"], _ = wait_layout(key, lambda lay: "(0.50)" in lay["layout"], "equal splits on the Mac")
    time.sleep(1)
    pq.shot("manage-after-equalized")
    pane_menu(j, right, "Close Pane")
    out["closed"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 1, "the close on the Mac")
    time.sleep(1)
    pq.shot("manage-after-closed")
    return out


def moves(j, label):
    """Move Tab to New Split › To the Right, Move Tab to Pane › Pane 2, Move Tab to New Column,
    then Undo Layout Change (no question) and a split's undo (the close question)."""
    ws, key, name = seed("moves", terminals=3)
    surfaces = {tab.get("name"): tab["surface"] for _, tab in t.ws_tabs(ws)}
    out = {"start": mac_layout(key)}
    if label == "before":
        return dict(before_menu(j, name, "moves-before-page-menu"), mac=out["start"])
    t.open_ws(j, name)
    t.open_tab(j, "p2tabs-t1")
    open_panes(j)
    pq.shot("moves-after-panes")
    tab_menu(j, surfaces["p2tabs-t2"], "Move Tab to New Split", "To the Right")
    out["to_split"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 2 and lay["panes"][1]["tabs"] == ["p2tabs-t2"],
                                     "t2 in a new right pane on the Mac")
    time.sleep(1)
    pq.shot("moves-after-split")
    tab_menu(j, surfaces["p2tabs-t3"], "Move Tab to Pane", "Pane 2")
    out["to_pane"], _ = wait_layout(key, lambda lay: (pane_of(lay, "p2tabs-t3") or {}).get("tabs") == ["p2tabs-t2", "p2tabs-t3"],
                                    "t3 beside t2 on the Mac")
    time.sleep(1)
    pq.shot("moves-after-pane")
    tab_menu(j, surfaces["p2tabs-t3"], "Move Tab to New Column")
    out["to_column"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 3 and lay["columns"] >= 2, "t3 in a new column on the Mac")
    time.sleep(1)
    pq.shot("moves-after-column")
    toolbar(j, "panes.layout", "Undo Layout Change")
    out["undo_move"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 2, "the column move undone on the Mac")
    time.sleep(1)
    pq.shot("moves-after-undo")
    # A split's undo closes the pane it made: the daemon asks first, and the phone asks the person.
    toolbar(j, "panes.add", "Split Down")
    wait_layout(key, lambda lay: len(lay["panes"]) == 3, "Split Down on the Mac")
    toolbar(j, "panes.layout", "Undo Layout Change")
    ask = j.sim.wait(label="Undo Layout Change?", timeout=8) or j.sim.wait(contains="closes 1 pane", timeout=4)
    check(ask, "no undo question")
    pq.shot("moves-after-undo-question")
    tap_row(j, "Undo")
    out["undo_split"], _ = wait_layout(key, lambda lay: len(lay["panes"]) == 2, "the split undone on the Mac")
    time.sleep(1)
    pq.shot("moves-after-undo-split")
    return out


def fork(j, label):
    """Fork Conversation… › To the Right, and › In a New Workspace, from a chat's page menu (before:
    the menu's Fork, which opens the copy in the same pane)."""
    ws, key, name = seed("fork", terminals=1)
    folder = pq.rsh(f"cd {t.PROJ} && pwd -P").stdout.strip()
    acpmux("acp.trust.set", {"cwd": folder, "level": "trusted"})
    sid = start_chat(folder, "Reply with the single word PONG.")
    pane = t.ws_tabs(ws)[0][0]
    host = pq.rsh("ps eww -o command -p $(pgrep -f 'panes-parity.app/Contents/Resources/bin/cmux-mobile-host') "
                  "| tr ' ' '\\n' | sed -n 's/^CMUX_MOBILE_AGENT_TAB_HOST=//p'").stdout.strip()
    check(host, "the rig Mac's agent tab host")
    t.mac_raw({"cmd": "new-conversation-tab", "pane": pane, "agent_session": {"host": host, "harness": "claude", "session": sid}})
    out = {"start": mac_layout(key), "session": sid}
    before_workspaces = {w.get("key") for w in t.mac_tree().get("workspaces", [])}
    t.open_ws(j, name)
    pq.open_grid(j)
    chat = [e for e in j.sim.find(suffix=", tab") if not (e.label or "").startswith("p2tabs-t")]
    check(chat, "no chat card")
    j.sim.tap_el(chat[0])
    time.sleep(2.5)
    labels = open_page_menu(j)
    out["page_menu"] = labels
    pq.shot(f"fork-{label}-page-menu")
    if label == "before":
        tap_row(j, "Fork")
        out["forked"] = fork_outcome(j, key, lambda lay: sum(k == "conversation" for p in lay["panes"] for k in p["kinds"]) == 2)
        pq.shot("fork-before-forked")
        return out
    tap_row(j, "Fork Conversation…")
    check(j.sim.wait(label="To the Right", timeout=6), "no fork destinations")
    pq.shot("fork-after-destinations")
    tap_row(j, "To the Right")
    out["forked_right"] = fork_outcome(j, key, lambda lay: len(lay["panes"]) == 2 and lay["panes"][1]["kinds"] == ["conversation"])
    pq.shot("fork-after-right")
    if "refused" in out["forked_right"]:
        return out
    open_page_menu(j)
    tap_row(j, "Fork Conversation…")
    tap_row(j, "In a New Workspace")
    def new_ws():
        made = [w for w in t.mac_tree().get("workspaces", []) if w.get("key") not in before_workspaces]
        return made or None
    made, _ = t.until(new_ws, timeout=90, what="the fork's new workspace on the Mac")
    out["new_workspace"] = [{"name": w.get("name"), "kinds": [tab.get("kind") for _, tab in t.ws_tabs(w)]} for w in made]
    time.sleep(2)
    pq.shot("fork-after-workspace")
    return out


def fork_outcome(j, key, test, timeout=90):
    """The fork on the Mac (its layout), or the phone's refusal toast (acpmux's own words)."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        lay = mac_layout(key)
        if test(lay):
            return {"mac": lay, "seconds": round(time.time() - t0, 1)}
        toast = [e.label for e in j.sim.find() if e.label and e.frame[1] < 200 and ("permissions" in e.label or "Couldn" in e.label)]
        if toast:
            return {"refused": toast[0], "mac": lay}
        time.sleep(0.4)
    raise Fail("neither a fork on the Mac nor a refusal")


FLOWS = {"split": split, "manage": manage, "moves": moves, "fork": fork}


def run(name, label):
    sim, mac, j = pq.ctx()
    pq.rec_start(f"{name}-{label}")
    try:
        out = FLOWS[name](j, label)
    finally:
        pq.rec_stop()
    path = os.path.join(pq.ART, f"{name}-{label}.json")
    os.makedirs(pq.ART, exist_ok=True)
    json.dump(out, open(path, "w"), indent=2)
    return out
