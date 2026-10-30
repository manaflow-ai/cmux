"""Tab group and screens parity flows (feat-cmux-next-ios-groups-screens-parity, cmux#25834 slice A
tab group rows and slice D screen rows): the Tab Group page (Set Tab Group Color…, Set / Remove Tab
Group Icon, Collapse / Expand, Move Tab Group Left / Right, to New Split / New Column / Workspace… /
New Workspace, New Tab in Group) and the Screens page (Select Screen, New Screen, Rename Screen…,
Close Screen), with each tab's screen on its card.

Same rig as pq.py and pq_tabs.py: the phone app in ONE headless simulator, the real tagged
cmux-next Mac app (rmac.py), the real link between them. Every action under test is done on the
phone; after each one the Mac's tree is read back from the rig app's own daemon (`list-workspaces`
over its socket, pq_tabs.mac_raw) and recorded in the flow's result.

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    PQ_HOST=local PQ_RBASE=~/cmux-next-ios-e2e/groups PQ_TAG=<rig tag> PQ_SIM=groups-phone \\
    PQ_STATE=~/cmux-next-ios-e2e/groups/state.json PQ_RAW=~/cmux-next-ios-e2e/groups/raw \\
    python3 -c 'import pq_groups as g; print(g.run("appearance", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch). Workspaces are named
`p2tabs-groups-*` / `p2tabs-screens-*` (pq_tabs.seed's prefix).
"""
import json
import os
import time

import pq
import pq_tabs as t
from journey import check


# ---------------------------------------------------------------- the Mac side (read only, plus seeding)

def mac_groups(key):
    """The workspace's tab groups on the Mac: [{id, name, color, icon, collapsed, pane, tabs}] in pane order,
    plus each pane's tab titles and the screen count."""
    ws = t.mac_workspace(key=key)
    check(ws, f"workspace {key} not on the Mac")
    groups, panes = [], []
    for screen in ws.get("screens", []):
        for pane in screen.get("panes", []):
            titles = {tab["surface"]: tab.get("name") or tab.get("title") for tab in pane.get("tabs", [])}
            panes.append({"id": pane.get("id"), "tabs": [titles[s] for s in titles]})
            for g in pane.get("tab_groups", []) or []:
                groups.append({"id": g.get("id"), "name": g.get("name"), "color": g.get("color"), "icon": g.get("icon"),
                               "collapsed": g.get("collapsed"), "pane": pane.get("id"),
                               "tabs": [titles.get(s) for s in g.get("surfaces", [])]})
    columns = max((len(s.get("columns") or []) for s in ws.get("screens", [])), default=0)
    return {"groups": groups, "panes": panes, "columns": columns}


def mac_screens(key):
    ws = t.mac_workspace(key=key)
    check(ws, f"workspace {key} not on the Mac")
    return [{"id": s.get("id"), "name": s.get("name") or "", "active": s.get("active"),
             "tabs": [tab.get("name") or tab.get("title") for p in s.get("panes", []) for tab in p.get("tabs", [])]}
            for s in ws.get("screens", [])]


def wait_mac(read, key, test, what, timeout=20):
    return t.until(lambda: (lambda v: v if test(v) else None)(read(key)), timeout=timeout, what=what)


def group(lay, name):
    return next((g for g in lay["groups"] if g["name"] == name), None)


def close_old_workspaces():
    """Rig setup: closes the rig's earlier flow workspaces (`p2tabs-*`), so pickers stay short."""
    for ws in t.mac_tree().get("workspaces", []):
        if (ws.get("name") or "").startswith("p2tabs-"):
            t.mac_raw({"cmd": "close-workspace", "workspace": ws["id"], "end_terminals": True})


def seed_group(tag, terminals, members, name):
    """A seeded workspace whose tabs `members` (1-based) the Mac groups as `name` (rig setup)."""
    ws = t.seed(f"{tag}", terminals=terminals)
    tabs = [tab for _, tab in t.ws_tabs(ws)]
    t.mac_raw({"cmd": "create-tab-group", "surfaces": [tabs[n - 1]["surface"] for n in members], "name": name, "color": "red"})
    return ws, ws["key"], ws.get("name") or ws.get("title")


# ---------------------------------------------------------------- the phone side

def labels(j):
    return [e.label for e in j.sim.find() if e.label and e.kind in ("Button", "PopUpButton", "MenuItem")]


def row(j, label=None, prefix=None, timeout=6):
    """A button (menu row, list row), scrolled into view in a long list or menu."""
    for attempt in range(6):
        e = starts(j, label, prefix, timeout if attempt == 0 else 2)
        if not e:
            # A row further down a long list is not built yet: scroll (menus never get here twice).
            if attempt >= 3:
                return None
            j.sim.swipe(215, 640, 215, 360, 0.4)
            time.sleep(0.8)
            continue
        x, y, w, h = e.frame
        if y + h < 830 and y > 100:
            return e
        j.sim.swipe(215, 640, 215, 360, 0.4) if y > 100 else j.sim.swipe(215, 360, 215, 640, 0.4)
        time.sleep(0.8)
        timeout = 2
    return None


# Rows the flows tap: buttons, a list row's pull-down menu (PopUpButton) and its menu items.
TAPPABLE = ("Button", "PopUpButton", "MenuItem")


def starts(j, label, prefix, timeout):
    """The first button labeled `label`, or whose label starts with `prefix` (sim.find's `prefix` matches
    only "<prefix>" or "<prefix>, …")."""
    t0 = time.time()
    while True:
        hits = [e for e in j.sim.find() if e.kind in TAPPABLE
                and (label is not None and e.label == label) or (prefix is not None and (e.label or "").startswith(prefix))]
        if hits:
            return hits[0]
        if time.time() - t0 > timeout:
            return None
        time.sleep(0.3)


def open_ws(j, name):
    """From a workspace's grid (its Workspaces button, which back_to_list does not know) or anywhere, the workspace."""
    leave = [e for e in j.sim.find(label="Workspaces", kind="Button") if e.frame[1] < 120]
    if leave:
        j.sim.tap_el(leave[0])
        time.sleep(1.5)
    t.open_ws(j, name)


def tap(j, label=None, prefix=None, timeout=6):
    e = row(j, label, prefix, timeout)
    check(e, f"no {label or prefix!r}; buttons: {labels(j)[:30]}")
    j.sim.tap_el(e)
    time.sleep(1.0)


def open_group_page(j, title):
    """A member card's long press, then its "Tab Group: <name>…" row (before: the dialog; after: the page)."""
    grid(j)
    e = t.card(j, title)
    x, y = e.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(0.9)
    tap(j, prefix="Tab Group: ")
    time.sleep(0.6)


def grid(j):
    """The workspace's tab grid: as it is when the workspace opened in it (its Done button and cards), else
    pq.open_grid."""
    if j.sim.find(label="Done", kind="Button") and j.sim.find(suffix=", tab", kind="Button"):
        return
    pq.open_grid(j)


def open_tab(j, title):
    grid(j)
    j.sim.tap_el(t.card(j, title))
    time.sleep(1.5)


def back(j):
    b = j.sim.find(ident="BackButton") or [e for e in j.sim.find(kind="Button") if e.frame[1] < 110 and e.frame[0] < 80]
    check(b, "no Back button")
    j.sim.tap_el(b[0])
    time.sleep(1.2)


def open_page_menu(j):
    bottom = [e for e in j.sim.find(kind="Button") if e.frame[1] > 740 and e.frame[2] > 120]
    check(bottom, "no title capsule at the bottom")
    j.sim.tap_el(bottom[0])
    time.sleep(1.2)
    return labels(j)


def close_menu(j):
    j.sim.tap(200, 300)
    time.sleep(0.8)


# ---------------------------------------------------------------- flows

def appearance(j, label):
    """Set Tab Group Color… › Purple, Set Tab Group Icon… › star, Collapse / Expand Tab Group, Remove
    Tab Group Icon, on a group of two tabs the Mac made (rig setup)."""
    ws, key, name = seed_group("groups-look", 2, [1, 2], "build")
    out = {"start": mac_groups(key)}
    open_ws(j, name)
    open_group_page(j, "p2tabs-t1")
    out["group_actions"] = labels(j)
    pq.shot(f"appearance-{label}-actions")
    if label == "before":
        out["has_color"] = any((x or "").startswith("Set Tab Group Color") for x in out["group_actions"])
        close_menu(j)  # the base app's group dialog has no Cancel row on iOS 26: a tap outside closes it
        return out
    tap(j, prefix="Set Tab Group Color")
    pq.shot("appearance-after-colors")
    tap(j, "Purple")
    out["color"], took = wait_mac(mac_groups, key, lambda v: (group(v, "build") or {}).get("color") == "purple", "the color on the Mac")
    out["color_s"] = round(took, 1)
    tap(j, prefix="Set Tab Group Icon")
    pq.shot("appearance-after-icons")
    tap(j, "star")
    out["icon"], _ = wait_mac(mac_groups, key, lambda v: (group(v, "build") or {}).get("icon") == "star", "the icon on the Mac")
    time.sleep(1)
    pq.shot("appearance-after-icon")
    tap(j, "Collapse Tab Group")
    out["collapsed"], _ = wait_mac(mac_groups, key, lambda v: (group(v, "build") or {}).get("collapsed") is True, "the collapse on the Mac")
    time.sleep(1)
    pq.shot("appearance-after-collapsed")
    tap(j, "Expand Tab Group")
    out["expanded"], _ = wait_mac(mac_groups, key, lambda v: (group(v, "build") or {}).get("collapsed") is False, "the expand on the Mac")
    back(j)
    time.sleep(1)
    pq.shot("appearance-after-card")  # the members' chip: purple, with the star
    open_group_page(j, "p2tabs-t1")
    tap(j, "Remove Tab Group Icon")
    out["icon_removed"], _ = wait_mac(mac_groups, key, lambda v: not (group(v, "build") or {}).get("icon"), "the icon removed on the Mac")
    time.sleep(1)
    pq.shot("appearance-after-icon-removed")
    return out


def moves(j, label):
    """Move Tab Group Right / Left, New Tab in Group, Move Tab Group to New Split › Below, to New
    Column, to Workspace… (another seeded workspace), then from there to New Workspace."""
    close_old_workspaces()
    ws, key, name = seed_group("groups-move", 4, [2, 3], "pair")
    other = t.seed("groups-dest", terminals=1)
    out = {"start": mac_groups(key)}
    open_ws(j, name)
    open_group_page(j, "p2tabs-t2")
    out["group_actions"] = labels(j)
    pq.shot(f"moves-{label}-actions")
    if label == "before":
        out["has_moves"] = any((x or "").startswith("Move Tab Group") for x in out["group_actions"])
        close_menu(j)  # the base app's group dialog has no Cancel row on iOS 26: a tap outside closes it
        return out
    tap(j, "Move Tab Group Right")
    out["right"], _ = wait_mac(mac_groups, key, lambda v: v["panes"][0]["tabs"] == ["p2tabs-t1", "p2tabs-t4", "p2tabs-t2", "p2tabs-t3"],
                               "the group after t4 on the Mac")
    tap(j, "Move Tab Group Left")
    out["left"], _ = wait_mac(mac_groups, key, lambda v: v["panes"][0]["tabs"] == ["p2tabs-t1", "p2tabs-t2", "p2tabs-t3", "p2tabs-t4"],
                              "the group back before t4 on the Mac")
    pq.shot("moves-after-left")
    tap(j, "New Tab in Group")
    out["new_tab"], took = wait_mac(mac_groups, key, lambda v: len((group(v, "pair") or {}).get("tabs", [])) == 3, "a third member on the Mac")
    out["new_tab_s"] = round(took, 1)
    time.sleep(1.5)
    pq.shot("moves-after-new-tab")
    # New Tab in Group opens the new tab: back to the group's page.
    open_group_page(j, "p2tabs-t2")
    tap(j, prefix="Move Tab Group to New Split")
    pq.shot("moves-after-split-menu")
    tap(j, "Below")
    out["split"], _ = wait_mac(mac_groups, key, lambda v: len(v["panes"]) == 2 and (group(v, "pair") or {}).get("pane") == v["panes"][1]["id"],
                               "the group in a new pane below on the Mac")
    time.sleep(1)
    pq.shot("moves-after-split")
    tap(j, "Move Tab Group to New Column")
    out["column"], _ = wait_mac(mac_groups, key, lambda v: v["columns"] >= 2, "the group in a new column on the Mac")
    time.sleep(1)
    pq.shot("moves-after-column")
    tap(j, prefix="Move Tab Group to Workspace")
    # The picker is a sheet the AX tree does not show: its row is found by OCR, scrolling the sheet.
    time.sleep(1.2)
    hits = []
    for _ in range(8):
        hits = [h for h in j.sim.ocr_find(other.get("name"), timeout=2) if h[1] > 440]
        if hits:
            break
        j.sim.swipe(200, 780, 200, 560, 0.4)
        time.sleep(0.8)
    check(hits, "the destination workspace is not in the picker")
    pq.shot("moves-after-workspace-picker")
    x, y, w, h, _ = hits[0]
    j.sim.tap(x + w / 2, y + h / 2)
    out["to_workspace"], _ = wait_mac(mac_groups, other["key"], lambda v: group(v, "pair") is not None, "the group in the other workspace on the Mac")
    out["source_after"] = mac_groups(key)
    time.sleep(1.5)
    pq.shot("moves-after-workspace")
    before_keys = {w.get("key") for w in t.mac_tree().get("workspaces", [])}
    open_ws(j, other.get("name"))
    open_group_page(j, "p2tabs-t2")
    tap(j, "Move Tab Group to New Workspace")

    def made():
        new = [w for w in t.mac_tree().get("workspaces", []) if w.get("key") not in before_keys]
        return new or None
    new, _ = t.until(made, timeout=30, what="the group's new workspace on the Mac")
    out["new_workspace"] = {"name": new[0].get("name"), **mac_groups(new[0]["key"])}
    time.sleep(1.5)
    pq.shot("moves-after-new-workspace")
    return out


def screens(j, label):
    """Screens (2) in the page menu, each card's screen, then New Screen, Rename Screen… "logs",
    Select Screen (Screen 1), Close Screen on the Screens page."""
    ws = t.seed("screens", terminals=2)
    key, name = ws["key"], ws.get("name")
    # Rig setup: a second screen on the Mac, so the phone has two to show.
    t.mac_raw({"cmd": "new-screen", "workspace": ws["id"]})
    out = {"start": mac_screens(key)}
    open_ws(j, name)
    grid(j)
    time.sleep(1)
    out["cards"] = [e.label for e in j.sim.find(suffix=", tab")]
    out["screen_labels"] = [e.label for e in j.sim.find(prefix="On Screen")]
    pq.shot(f"screens-{label}-grid")
    open_tab(j, "p2tabs-t1")
    out["page_menu"] = open_page_menu(j)
    pq.shot(f"screens-{label}-page-menu")
    if label == "before":
        out["has_screens"] = any((x or "").startswith("Screens") for x in out["page_menu"])
        close_menu(j)
        return out
    tap(j, prefix="Screens")
    check(j.sim.wait(ident="screens.page", timeout=8) or j.sim.wait(label="Screens", timeout=4), "the Screens page did not open")
    time.sleep(0.8)
    pq.shot("screens-after-page")
    screens_now = out["start"]
    first, second = screens_now[0]["id"], screens_now[1]["id"]
    j.sim.tap_el(j.sim.wait(ident="screens.new", timeout=6))
    out["new"], took = wait_mac(mac_screens, key, lambda v: len(v) == 3, "a third screen on the Mac")
    out["new_s"] = round(took, 1)
    time.sleep(1.5)
    pq.shot("screens-after-new")
    # New Screen opens its tab on the phone: back to the Screens page.
    open_page_menu(j)
    tap(j, prefix="Screens")
    time.sleep(0.8)
    j.sim.tap_el(j.sim.wait(ident=f"screens.menu.{second}", timeout=6))
    time.sleep(0.8)
    pq.shot("screens-after-menu")
    tap(j, "Rename Screen…")
    check(j.sim.wait(ident="screens.rename.field", timeout=4) or j.sim.wait(kind="TextField", timeout=4), "no Rename Screen field")
    pq.type_text("logs")
    time.sleep(0.5)
    pq.shot("screens-after-rename-field")
    tap(j, "Rename")
    out["renamed"], _ = wait_mac(mac_screens, key, lambda v: any(s["name"] == "logs" for s in v), "the name on the Mac")
    time.sleep(1)
    current = next(s["id"] for s in out["renamed"] if s["active"])
    target = first if current != first else second
    j.sim.tap_el(j.sim.wait(ident=f"screens.menu.{target}", timeout=6))
    time.sleep(0.8)
    tap(j, "Select Screen")
    out["selected"], _ = wait_mac(mac_screens, key, lambda v: next(s for s in v if s["id"] == target)["active"], "the selected screen on the Mac")
    time.sleep(1)
    pq.shot("screens-after-select")
    j.sim.tap_el(j.sim.wait(ident=f"screens.menu.{second}", timeout=6))
    time.sleep(0.8)
    tap(j, "Close Screen")
    ask = j.sim.wait(label="Close", kind="Button", timeout=3)
    if ask:
        j.sim.tap_el(ask)
    out["closed"], _ = wait_mac(mac_screens, key, lambda v: len(v) == 2 and all(s["id"] != second for s in v), "the close on the Mac")
    time.sleep(1.5)
    pq.shot("screens-after-close")
    back(j)
    grid(j)
    time.sleep(1)
    out["cards_after"] = [e.label for e in j.sim.find(suffix=", tab")]
    out["screen_labels_after"] = [e.label for e in j.sim.find(prefix="On ")]
    pq.shot("screens-after-grid")
    return out


FLOWS = {"appearance": appearance, "moves": moves, "screens": screens}


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
