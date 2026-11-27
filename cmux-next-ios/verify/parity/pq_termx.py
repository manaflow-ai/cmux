"""Terminal tools parity flows (feat-cmux-next-ios-terminal-tools-parity): Copy Mode and
Select Text…, Select All, Send Text…, Scroll to Top, the New Tab rows, Clear Tab Name, the
Copy rows, Duplicate Workspace (with and without browser tabs) and Send feedback. Same rig as
pq_terminal.py: the phone app in ONE headless simulator on the rig mini, the real tagged
cmux-next Mac app (rmac.py), the real link between them. The Mac side is seeded on its own
daemon socket and read back there; every action under test is done on the phone (taps, and
hardware keys from axe, which reach the simulator as a hardware keyboard). What the phone
copied is read from the simulator's pasteboard (`simctl pbpaste`).

    source ~/cmux-next-ios-e2e/termx/env.sh
    python3 -c 'import pq_termx as x; print(x.run("copymode", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import re
import subprocess
import time

import pq
import pq_tabs as t
from journey import Fail, check

# HID usages (axe key): letters a=4 ... z=29, 0=39, Escape=41; modifiers Shift=225, Command=227.
KEY = {c: 4 + i for i, c in enumerate("abcdefghijklmnopqrstuvwxyz")}
KEY.update({"0": 39, "esc": 41, "4": 33})
SHIFT, CMD = 225, 227


def udid():
    return pq.load()["udid"]


def key(name):
    subprocess.run(["axe", "key", str(KEY[name]), "--udid", udid()], capture_output=True, timeout=30)
    time.sleep(0.35)


def combo(mods, name):
    subprocess.run(["axe", "key-combo", "--modifiers", ",".join(str(m) for m in mods), "--key", str(KEY[name]),
                    "--udid", udid()], capture_output=True, timeout=30)
    time.sleep(0.35)


def pasteboard():
    return subprocess.run(["xcrun", "simctl", "pbpaste", udid()], capture_output=True, text=True).stdout


def clear_pasteboard():
    subprocess.run(["xcrun", "simctl", "pbcopy", udid()], input="(empty)", text=True, capture_output=True)


def menu_rows(j, tries=3):
    """The page menu's rows (opened with a tap on the bottom title capsule); left open. A tap
    while the last menu is still closing is lost, so it taps again until the menu shows."""
    rows = []
    for _ in range(tries):
        time.sleep(0.8)
        bottom = [e for e in j.sim.find(kind="Button") if e.frame[1] > 740 and e.frame[2] > 120]
        check(bottom, "no title capsule at the bottom")
        j.sim.tap_el(bottom[0])
        time.sleep(1.2)
        rows = [e.label for e in j.sim.find(kind="Button") if e.label]
        if "Close Tab" in rows or "Rename Tab…" in rows:
            return rows
    return rows


def close_menu(j):
    j.sim.tap(200, 140)
    time.sleep(0.8)


def tap_menu(j, title, scroll=True):
    """A page menu row (the menu scrolls when it is long)."""
    row = j.sim.wait(label=title, kind="Button", timeout=3)
    for _ in range(6 if scroll else 0):
        if row and 60 < row.frame[1] and row.frame[1] + row.frame[3] < 800:
            break
        if row and row.frame[1] <= 60:
            j.sim.swipe(200, 300, 200, 600, 0.3)  # above the screen: scroll the menu down
        else:
            j.sim.swipe(200, 600, 200, 300, 0.3)
        time.sleep(0.6)
        row = j.sim.wait(label=title, kind="Button", timeout=2)
    check(row, f"no {title!r} in the page menu: {[e.label for e in j.sim.find(kind='Button')][:30]}")
    time.sleep(0.5)
    row = j.sim.wait(label=title, kind="Button", timeout=2) or row
    j.sim.tap_el(row)
    time.sleep(1.0)


def menu_item(j, title, tries=6):
    """A row of an open context menu, scrolled into view (a long menu scrolls)."""
    for _ in range(tries):
        item = j.sim.wait(label=title, kind="Button", timeout=2)
        if item and item.frame[1] + item.frame[3] < 700:
            return item
        j.sim.swipe(140, 640, 140, 380, 0.4)
        time.sleep(0.6)
    return None


def seed_terminal(flow, lines):
    name, surface = seed(flow)
    t.mac_raw({"cmd": "send", "surface": surface, "text": lines + "\r"})
    return name, surface


def seed(flow, terminals=1):
    ws = t.seed(f"tx-{flow}", terminals=terminals)
    name = ws.get("name") or ws.get("title")
    return name, t.ws_tabs(ws)[0][1]["surface"]


def screen_text(surface):
    data = t.mac_raw({"cmd": "read-screen", "surface": surface})
    return data.get("text") or "\n".join(data.get("lines") or [])


# ---------------------------------------------------------------- flows

def copymode(j, label):
    """Select Text… then vi keys from a hardware keyboard: k up a row, 0, v, $ and y copy the
    row the Mac printed; Shift-Cmd-M also enters Copy Mode and Escape leaves it."""
    stamp = time.strftime("%H%M%S")
    name, surface = seed_terminal("copy", f'printf "alpha-{stamp} one\\nbravo-{stamp} two words\\ncharlie-{stamp} three\\n"')
    t.open_ws(j, name)
    j.sim.ocr_find(f"charlie-{stamp}", timeout=20)
    rows = menu_rows(j)
    pq.shot(f"copymode-{label}-menu")
    if label == "before":
        close_menu(j)
        check("Select Text…" not in rows, "the base app has Select Text…")
        return {"page_menu": rows, "select_text": False}
    check("Select Text…" in rows, f"no Select Text… in {rows}")
    clear_pasteboard()
    tap_menu(j, "Select Text…")
    bar = j.sim.wait(ident="terminal.copyMode", timeout=5) or j.sim.wait(label="Copy Mode", timeout=3)
    check(bar, "no Copy Mode bar")
    pq.shot(f"copymode-{label}-entered")
    # Select Text… selected the cursor's row (the prompt): v ends that selection, k k goes up
    # to "bravo" (prompt, charlie, bravo), then 0 v $ selects the row and y copies it.
    key("v")
    for _ in range(2):
        key("k")
    key("0")
    key("v")
    combo([SHIFT], "4")  # $
    pq.shot(f"copymode-{label}-visual")
    key("y")
    time.sleep(0.8)
    copied = pasteboard()
    gone = not j.sim.find(ident="terminal.copyMode")
    pq.shot(f"copymode-{label}-copied")
    # Shift-Cmd-M, w and the Copy button: the cursor row's next word.
    clear_pasteboard()
    j.sim.tap(200, 450)
    time.sleep(0.6)
    combo([SHIFT, CMD], "m")
    entered = bool(j.sim.wait(ident="terminal.copyMode", timeout=4))
    key("g")  # first row
    key("v")
    key("w")
    pq.shot(f"copymode-{label}-keyboard")
    key("esc")
    left = not j.sim.find(ident="terminal.copyMode")
    # The Mac's own row, for comparison.
    mac = [r for r in screen_text(surface).splitlines() if r.startswith(f"bravo-{stamp}")]
    return {"copied": copied, "mac_row": mac[0].rstrip() if mac else None, "matches_mac": bool(mac) and copied.strip() == mac[0].strip(),
            "bar_left_after_y": gone, "shift_cmd_m_entered": entered, "escape_left": left}


def termtools(j, label):
    """Select All (copies the scrollback), Send Text… (types on the Mac, no Return) and
    Scroll to Top (the first rows show) from the page menu."""
    stamp = time.strftime("%H%M%S")
    name, surface = seed_terminal("tools", f"for i in $(seq 1 200); do echo row-$i-{stamp}; done")
    t.open_ws(j, name)
    j.sim.ocr_find(f"row-200-{stamp}", timeout=25)
    rows = menu_rows(j)
    pq.shot(f"termtools-{label}-menu")
    want = ["Select All", "Send Text…", "Scroll to Top"]
    if label == "before":
        close_menu(j)
        return {"page_menu": rows, "present": [w for w in want if w in rows]}
    out = {"present": [w for w in want if w in rows]}
    # Scroll to Top.
    tap_menu(j, "Scroll to Top")
    time.sleep(1.5)
    top = j.sim.ocr_find(f"row-1-{stamp}", timeout=6)
    pq.shot(f"termtools-{label}-top")
    out["scroll_to_top_shows_row_1"] = bool(top)
    # Select All, then Copy in the edit menu.
    clear_pasteboard()
    menu_rows(j)
    tap_menu(j, "Select All")
    pq.shot(f"termtools-{label}-select-all")
    copy = j.sim.wait(label="Copy", timeout=5)
    check(copy, "no Copy in the edit menu after Select All")
    j.sim.tap_el(copy)
    time.sleep(0.8)
    pb = pasteboard()
    out["select_all_copied_rows"] = len(re.findall(rf"row-\d+-{stamp}", pb))
    out["select_all_has_first_and_last"] = f"row-1-{stamp}" in pb and f"row-200-{stamp}" in pb
    # Send Text….
    menu_rows(j)
    tap_menu(j, "Send Text…")
    field = j.sim.wait(ident="terminal.sendText.field", timeout=5) or j.sim.wait(kind="TextField", timeout=3)
    check(field, "no Send Text field")
    j.sim.tap_el(field)
    pq.type_text(f"echo sent{stamp}ok")
    pq.shot(f"termtools-{label}-send-text")
    # The alert's Send, not the composer's (`terminal.composer.send`).
    send = [e for e in j.sim.find(label="Send", kind="Button") if e.ident != "terminal.composer.send"]
    check(send, "no Send button in the alert")
    j.sim.tap_el(send[0])
    typed, took = t.until(lambda: f"echo sent{stamp}ok" in screen_text(surface), timeout=15,
                          what="the text on the Mac's terminal")
    time.sleep(1.5)
    out["send_text_on_mac_s"] = round(took, 1)
    # No Return: the line waits at the prompt, its output never printed on a row of its own.
    out["send_text_ran"] = any(r.strip() == f"sent{stamp}ok" for r in screen_text(surface).splitlines())
    out["mac_prompt_line"] = [r for r in screen_text(surface).splitlines() if f"sent{stamp}ok" in r][-1:]
    pq.shot(f"termtools-{label}-sent")
    # Clean the typed line off the prompt (Ctrl-U on the Mac).
    t.mac_raw({"cmd": "send", "surface": surface, "text": "\u0015"})
    return out


def newtabs(j, label):
    """New Tab at Start and New Tab to the Right on the second of three terminals: the Mac's
    pane order has the new terminal first, then right after it."""
    name, _ = seed("newtab", terminals=3)
    t.open_ws(j, name)
    t.open_tab(j, "p2tabs-t2")
    rows = menu_rows(j)
    pq.shot(f"newtabs-{label}-menu")
    want = ["New Tab to the Right", "New Tab of the Same Kind", "New Tab at Start", "New Tab at End"]
    if label == "before":
        close_menu(j)
        return {"present": [w for w in want if w in rows]}

    def order():
        return [(tab.get("name") or tab.get("kind")) for _, tab in t.ws_tabs(t.mac_workspace(name=name))]

    before = order()
    tap_menu(j, "New Tab at Start")
    t.until(lambda: len(order()) == len(before) + 1, timeout=20, what="the new tab at start")
    time.sleep(2)
    after_start = order()
    pq.shot(f"newtabs-{label}-start")
    # Back to t2, then New Tab to the Right.
    t.open_tab(j, "p2tabs-t2")
    menu_rows(j)
    tap_menu(j, "New Tab to the Right")
    t.until(lambda: len(order()) == len(before) + 2, timeout=20, what="the new tab to the right")
    time.sleep(2)
    after_right = order()
    pq.shot(f"newtabs-{label}-right")
    return {"before": before, "after_start": after_start, "after_right": after_right,
            "start_is_first": after_start[0] not in before,
            "right_follows_t2": after_right.index("p2tabs-t2") + 1 < len(after_right)
            and after_right[after_right.index("p2tabs-t2") + 1] not in before}


def names_ids(j, label):
    """Clear Tab Name (the Mac's name goes), Copy Tab Link / Copy IDs (the Mac's ids) and the
    row menu's Copy Workspace ID."""
    name, surface = seed("names", terminals=2)
    t.open_ws(j, name)
    t.open_tab(j, "p2tabs-t1")
    rows = menu_rows(j)
    pq.shot(f"names-{label}-menu")
    want = ["Clear Tab Name", "Copy Tab Link", "Copy Tab ID", "Copy Pane Link", "Copy Pane ID", "Copy IDs"]
    if label == "before":
        close_menu(j)
        return {"present": [w for w in want if w in rows]}
    out = {"present": [w for w in want if w in rows]}
    ws = t.mac_workspace(name=name)
    tab = next(tb for _, tb in t.ws_tabs(ws) if tb["surface"] == surface)
    pane = next(p for p, tb in t.ws_tabs(ws) if tb["surface"] == surface)
    pane_rid = next(p.get("resource_id") for s in ws["screens"] for p in s["panes"] if p["id"] == pane)
    clear_pasteboard()
    tap_menu(j, "Copy Tab Link")
    out["copy_tab_link"] = pasteboard()
    out["mac_tab_link_id"] = tab.get("tab_resource_id")
    out["tab_link_matches"] = out["copy_tab_link"] == f"cmux://tab/{tab.get('tab_resource_id')}"
    menu_rows(j)
    tap_menu(j, "Copy IDs")
    out["copy_ids"] = pasteboard()
    out["ids_match"] = out["copy_ids"] == (f"workspace_id={ws.get('resource_id')}\npane_id={pane_rid}\n"
                                           f"surface_id={tab.get('tab_resource_id')}")
    menu_rows(j)
    tap_menu(j, "Clear Tab Name")
    cleared, took = t.until(lambda: not next(tb for _, tb in t.ws_tabs(t.mac_workspace(name=name))
                                             if tb["surface"] == surface).get("name"), timeout=15,
                            what="the Mac to clear the tab's name")
    out["clear_name_s"] = round(took, 1)
    time.sleep(1.5)
    pq.shot(f"names-{label}-cleared")
    # The workspace row menu: Copy > Copy Workspace ID.
    j.back_to_list()
    row = j.sim.wait(prefix=name, kind="Button", timeout=20)
    check(row, "no workspace row")
    x, y = row.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(1.0)
    copy = menu_item(j, "Copy")
    check(copy, f"no Copy in the row menu: {[e.label for e in j.sim.find(kind='Button')][:30]}")
    j.sim.tap_el(copy)
    time.sleep(0.8)
    pq.shot(f"names-{label}-row-copy")
    clear_pasteboard()
    item = j.sim.wait(label="Copy Workspace ID", kind="Button", timeout=5)
    check(item, "no Copy Workspace ID")
    j.sim.tap_el(item)
    time.sleep(0.8)
    out["copy_workspace_id"] = pasteboard()
    out["workspace_id_matches"] = out["copy_workspace_id"] == f"workspace_id={ws.get('resource_id')}"
    return out


def dup_seed():
    """A workspace with a side by side split (ratio 0.3), a web page in the right pane, a
    color and an icon, set on the Mac (setup)."""
    name, surface = seed("dup", terminals=1)
    ws = t.mac_workspace(name=name)
    pane = t.ws_tabs(ws)[0][0]
    t.mac_raw({"cmd": "split", "pane": pane, "dir": "right"})
    ws = t.mac_workspace(name=name)
    right = [p for p, _ in t.ws_tabs(ws) if p != pane][0]
    t.mac_raw({"cmd": "new-browser-tab", "pane": right, "url": "https://example.com/"})
    layout = ws["screens"][0]["layout"]
    if layout.get("type") == "split":
        t.mac_raw({"cmd": "set-split-ratio", "split": layout["split"], "ratio": 0.3})
    t.mac_raw({"cmd": "set-workspace-metadata", "key": ws["key"], "color": "purple", "icon": "star"})
    return name


def shape(ws):
    """What a duplicate keeps: color, icon, each screen's split (dir, ratio) and its panes' tab kinds."""
    out = {"color": ws.get("color"), "icon": ws.get("icon"), "screens": []}
    for s in ws.get("screens", []):
        layout = s.get("layout") or {}
        out["screens"].append({
            "split": (layout.get("dir"), round(layout.get("ratio", 0), 2)) if layout.get("type") == "split" else None,
            "panes": [[tb.get("kind") for tb in p.get("tabs", [])] for p in s.get("panes", [])],
        })
    return out


def duplicate(j, label, browsers=True):
    name = dup_seed()
    source = shape(t.mac_workspace(name=name))
    before = {ws.get("key") for ws in t.mac_tree().get("workspaces", [])}
    j.back_to_list()
    row = j.sim.wait(prefix=name, kind="Button", timeout=30)
    check(row, "no workspace row")
    x, y = row.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(1.2)
    title = "Duplicate Workspace" if browsers else "Duplicate Workspace Without Browser Tabs"
    item = menu_item(j, title)
    pq.shot(f"dup{'' if browsers else '-nobrowser'}-{label}-menu")
    if not item:
        j.sim.tap(200, 100)
        check(label == "before", f"no {title!r} in the row menu")
        return {"source": source, "offered": False}
    j.sim.tap_el(item)

    def copy():
        for ws in t.mac_tree().get("workspaces", []):
            if ws.get("key") not in before and (ws.get("name") == name or ws.get("title") == name):
                tabs = [tb for _, tb in t.ws_tabs(ws)]
                if tabs and all(tb.get("kind") for tb in tabs):
                    return ws
        return None

    ws, took = t.until(copy, timeout=40, what="the duplicate on the Mac")
    time.sleep(4)
    made = shape(t.mac_workspace(key=ws.get("key")))
    pq.shot(f"dup{'' if browsers else '-nobrowser'}-{label}-done")
    return {"source": source, "copy": made, "listed_s": round(took, 1), "offered": True}


def dup(j, label):
    return duplicate(j, label, browsers=True)


def dupnobrowser(j, label):
    return duplicate(j, label, browsers=False)


def feedback(j, label):
    """Settings > About: Send feedback opens the Mac's feedback page (a new issue) in Safari."""
    j.back_to_list()
    j.tab("Settings")
    time.sleep(1.5)
    row = t.scroll_to(j, label="Send feedback") if label == "after" else None
    rows = [e.label for e in j.sim.find(kind="Button") if e.label]
    pq.shot(f"feedback-{label}-settings")
    if label == "before":
        old = t.scroll_to(j, label="Report a problem")
        pq.shot(f"feedback-{label}-settings")
        return {"send_feedback": False, "report_a_problem": bool(old)}
    check(row, f"no Send feedback in Settings: {rows[:30]}")
    j.sim.tap_el(row)
    time.sleep(6)
    pq.shot(f"feedback-{label}-opened")
    front = subprocess.run(["xcrun", "simctl", "spawn", udid(), "launchctl", "list"], capture_output=True, text=True).stdout
    return {"send_feedback": True, "safari_running": "com.apple.mobilesafari" in front, "ocr": " | ".join(o[4] for o in j.sim.ocr())[:300]}


FLOWS = {"copymode": copymode, "termtools": termtools, "newtabs": newtabs, "names": names_ids, "dup": dup,
         "dupnobrowser": dupnobrowser, "feedback": feedback}


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
