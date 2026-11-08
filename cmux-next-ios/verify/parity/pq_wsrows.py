"""Workspace-rows parity flows (feat-cmux-next-ios-ws-rows-parity): New Workspace Above / Below /
at Top / in Group, Merge Workspace Into…, New Workspace Group and Duplicate Workspace Group, the
full icon picker, Group by Folder, Resize Pane, Move Tab to New Dock Column, Move Pane to New
Workspace and Duplicate Screen.

Same rig as pq_rows.py: the phone app in ONE headless simulator on the rig mini, the real tagged
cmux-next Mac app (rmac.py), the real link between them. Every action under test is done on the
phone; the Mac's state is then read back from the rig app's own daemon socket (`list-workspaces`,
`list-personal`). Setup (seeding workspaces, groups, splits) is done on the Mac side.

    . ~/cmux-next-ios-e2e/wsrows/env.sh && python3 -c 'import pq_wsrows as w; print(w.run("place", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import time

import pq
import pq_panes as p
import pq_rows as r
import pq_tabs as t
from journey import Fail, check

r.PREFIX = PREFIX = "wsr-"


def keys():
    return {w.get("key") for w in t.mac_tree().get("workspaces", [])}


def by_key(key):
    return t.mac_workspace(key=key)


def personal_row(key):
    registry = t.mac_tree().get("registry_id")
    return next((row for row in r.personal().get("workspaces", []) if row.get("workspace_key") == key and row.get("session_id") == registry), None)


def order_keys():
    """This session's workspace keys in the person's order."""
    registry = t.mac_tree().get("registry_id")
    rows = sorted((row for row in r.personal().get("workspaces", []) if row.get("session_id") == registry), key=lambda row: row.get("index", 0))
    return [row["workspace_key"] for row in rows]


def new_key(before, what, timeout=40):
    """The key of a workspace the Mac lists now and did not before."""
    found, _ = t.until(lambda: next(iter(keys() - before), None), timeout=timeout, what=what)
    return found


def close_keys(made):
    for key in made:
        if by_key(key):
            t.mac_raw({"cmd": "close-workspace", "key": key, "end_terminals": True})


def back(j):
    """Back to the Workspaces list (a new workspace opens at once)."""
    time.sleep(2)
    j.back_to_list()
    time.sleep(1.5)


def open_new_workspace_menu(j):
    """The + button held: its menu (a tap makes a workspace)."""
    e = j.sim.wait(ident="workspaces.new", timeout=8)
    check(e, "no New Workspace button")
    x, y = e.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(1.2)
    return r.labels(j)


# ---------------------------------------------------------------- flows

def place(j, label):
    """Loose a, b and group G (c, d). Row b > New Workspace Below; row c > New Workspace Above; row a >
    New Workspace at Top; G's header > New Workspace in Group. Each new workspace's place is read from
    the Mac's personal order and groups."""
    r.close_mine()
    a, b, c, d = (f"{PREFIX}{x}" for x in "abcd")
    r.make([a, b, c, d])
    gid = r.group(f"{PREFIX}G", [c, d])
    ws = r.workspaces()
    out = {"start": r.order([a, b, c, d]), "groups": r.groups()}
    made = []
    try:
        out["row_menu"] = r.row_menu(j, b)
        pq.shot(f"place-{label}-menu")
        if label == "before":
            out["has_rows"] = "New" in out["row_menu"]
            r.dismiss(j)
            return out
        r.tap(j, "New")
        out["new_folder"] = r.labels(j)
        pq.shot("place-after-new-folder")
        before = keys()
        r.tap(j, "New Workspace Below")
        key = new_key(before, "the new workspace below b")
        made.append(key)
        o, took = r.wait_mac(lambda: (lambda o: o if key in o and o.index(key) == o.index(ws[b]["key"]) + 1 else None)(order_keys()),
                             "the new workspace right after b")
        out["below"] = {"key": key, "after_b": True, "s": round(took, 1), "group": (personal_row(key) or {}).get("group")}
        back(j)
        pq.shot("place-after-below")
        r.row_menu(j, c)
        r.tap(j, "New")
        before = keys()
        r.tap(j, "New Workspace Above")
        key = new_key(before, "the new workspace above c")
        made.append(key)
        r.wait_mac(lambda: (personal_row(key) or {}).get("group") == gid or None, "the new workspace in G")
        o, took = r.wait_mac(lambda: (lambda o: o if key in o and o.index(key) + 1 == o.index(ws[c]["key"]) else None)(order_keys()),
                             "the new workspace right before c")
        out["above"] = {"key": key, "group": gid, "before_c": True, "s": round(took, 1)}
        back(j)
        pq.shot("place-after-above")
        r.row_menu(j, a)
        r.tap(j, "New")
        before = keys()
        r.tap(j, "New Workspace at Top")
        key = new_key(before, "the new workspace at the top")
        made.append(key)
        mine = lambda: [k for k in order_keys() if k in {w["key"] for w in r.workspaces().values()}]
        # Above every loose row. A group shows before the row its `top_index` names, and a phone may
        # not change a group's place, so a group at the very top stays above it (as it does above a
        # row moved to the top).
        loose = lambda: [ws[a]["key"], ws[b]["key"]]
        o, took = r.wait_mac(lambda: (lambda o: o if key in o and o.index(key) < min(o.index(k) for k in loose()) else None)(order_keys()),
                             "the new workspace above every loose seeded row")
        out["top"] = {"key": key, "s": round(took, 1)}
        back(j)
        pq.shot("place-after-top")
        r.row_menu(j, a)
        r.tap(j, "New")
        before = keys()
        r.tap(j, "New Workspace at Bottom")
        key = new_key(before, "the new workspace at the bottom")
        made.append(key)
        o, took = r.wait_mac(lambda: (lambda o: o if o and o.index(key) > max(o.index(w["key"]) for w in r.mine().values()) else None)(mine()),
                             "the new workspace below every seeded one")
        out["bottom"] = {"key": key, "s": round(took, 1)}
        back(j)
        pq.shot("place-after-bottom")
        for _ in range(4):
            r.hold(j, r.group_header(j, gid))
            if j.sim.find(label="New Workspace in Group", kind="Button"):
                break
            r.dismiss(j)
        out["group_menu"] = r.labels(j)
        pq.shot("place-after-group-menu")
        before = keys()
        r.tap(j, "New Workspace in Group")
        key = new_key(before, "the new workspace in G")
        made.append(key)
        _, took = r.wait_mac(lambda: (personal_row(key) or {}).get("group") == gid or None, "the new workspace in G")
        out["in_group"] = {"key": key, "group": gid, "s": round(took, 1)}
        back(j)
        out["end"] = {"order": order_keys(), "groups": r.groups()}
        pq.shot("place-after-end")
        return out
    finally:
        close_keys(made)


def merge(j, label):
    """m1 (two terminals) > Move > Merge Workspace Into… > m2: m2 holds all three tabs, m1 is gone."""
    r.close_mine()
    m1, m2 = t.seed("x", terminals=2), t.seed("y", terminals=1)
    for ws, name in ((m1, f"{PREFIX}m1"), (m2, f"{PREFIX}m2")):
        t.mac_raw({"cmd": "rename-workspace", "key": ws["key"], "name": name})
    surfaces = [tab["surface"] for _, tab in t.ws_tabs(m1)]
    out = {"m1": surfaces, "m2": [tab["surface"] for _, tab in t.ws_tabs(m2)]}
    r.row_menu(j, f"{PREFIX}m1")
    r.tap(j, "Move")
    out["move_folder"] = r.labels(j)
    pq.shot(f"merge-{label}-move")
    if label == "before":
        out["has_rows"] = "Merge Workspace Into…" in out["move_folder"]
        r.dismiss(j)
        return out
    r.tap(j, "Merge Workspace Into…")
    pq.shot("merge-after-targets")
    r.tap(j, f"{PREFIX}m2")
    moved, took = r.wait_mac(lambda: (lambda w: w if w and all(s in [tab["surface"] for _, tab in t.ws_tabs(w)] for s in surfaces) else None)(by_key(m2["key"])),
                             "m1's tabs in m2")
    out["m2_after"] = [tab["surface"] for _, tab in t.ws_tabs(moved)]
    out["m1_gone"] = r.wait_mac(lambda: by_key(m1["key"]) is None or None, "m1 closed once empty")[0]
    out["s"] = round(took, 1)
    time.sleep(1.5)
    pq.shot("merge-after-done")
    return out


def groups(j, label):
    """+ (held) > New Workspace Group… "wsr-Empty": an empty group on the Mac, an empty header on the
    phone. Then G (two members) > Duplicate Workspace Group: a second G with a copy of each member."""
    r.close_mine()
    a, b = f"{PREFIX}g1", f"{PREFIX}g2"
    r.make([a, b])
    gid = r.group(f"{PREFIX}G", [a, b], color="purple")
    out = {"start": r.groups()}
    before_keys = keys()
    made = []
    try:
        out["new_menu"] = open_new_workspace_menu(j)
        pq.shot(f"groups-{label}-new-menu")
        if label == "before":
            out["has_new_group"] = "New Workspace Group…" in out["new_menu"]
            r.dismiss(j)
            r.group_menu(j, gid)
            out["group_menu"] = r.labels(j)
            out["has_duplicate"] = "Duplicate Workspace Group" in out["group_menu"]
            pq.shot("groups-before-group-menu")
            r.dismiss(j)
            return out
        r.tap(j, "New Workspace Group…")
        # The alert's field has the focus (an alert's field shows no identifier to the tree).
        check(j.sim.wait(label="New Workspace Group", timeout=6) or j.sim.wait(contains="empty group", timeout=3), "no New Workspace Group alert")
        field = j.sim.wait(ident="workspaces.newGroup.name", timeout=2) or j.sim.wait(kind="TextField", timeout=2)
        if field:
            j.sim.tap_el(field)
        pq.type_text(f"{PREFIX}Empty")
        pq.shot("groups-after-name")
        r.tap(j, "Create")
        made_group, took = r.wait_mac(lambda: r.groups().get(f"{PREFIX}Empty"), "the empty group on the Mac")
        out["empty"] = dict(made_group, s=round(took, 1))
        header = j.sim.wait(ident=f"workspace.group.{made_group['id']}", timeout=20)
        out["empty_header_on_phone"] = bool(header)
        pq.shot("groups-after-empty-header")
        r.group_menu(j, gid)
        out["group_menu"] = r.labels(j)
        pq.shot("groups-after-group-menu")
        r.tap(j, "Duplicate Workspace Group")
        dup, took = r.wait_mac(lambda: next((g for g in r.personal().get("groups", []) if g.get("name") == f"{PREFIX}G" and g["id"] != gid
                                             and len([w for w in r.personal().get("workspaces", []) if w.get("group") == g["id"]]) == 2), None),
                               "a second G with two copies", timeout=60)
        made = list(keys() - before_keys)
        out["duplicate"] = {"group": dup["id"], "color": dup.get("color"), "members": len(made), "s": round(took, 1)}
        time.sleep(2)
        pq.shot("groups-after-duplicate")
        return out
    finally:
        # The copies, and any workspace a hold on + that read as a tap made.
        close_keys(set(made) | (keys() - before_keys))
        for name, g in r.groups().items():
            if (name or "").startswith(PREFIX):
                r.v2("workspace_group.delete", {"workspace_group": g["id"]})


def icon(j, label):
    """Row > Appearance > Set Icon…: the picker; search "tortoise" (not one of the old 16) and tap it.
    The Mac's workspace icon becomes `tortoise`."""
    r.close_mine()
    name = f"{PREFIX}icon"
    ws = r.make([name])[0]
    r.row_menu(j, name)
    r.tap(j, "Appearance")
    out = {"appearance": r.labels(j)}
    pq.shot(f"icon-{label}-appearance")
    r.tap(j, "Set Icon…")
    out["picker"] = r.labels(j)[:40]
    pq.shot(f"icon-{label}-picker")
    if label == "before":
        out["has_tortoise"] = "tortoise" in out["picker"]
        r.dismiss(j)
        return out
    check(j.sim.wait(ident="iconPicker", timeout=8) or j.sim.wait(label="Set Icon", timeout=4), "no icon picker")
    search = j.sim.wait(contains="Search symbols", timeout=4) or j.sim.wait(kind="SearchField", timeout=2) \
        or j.sim.wait(kind="TextField", contains="Search", timeout=2)
    if search:
        j.sim.tap_el(search)
    else:
        # The sheet's search bar under its title (the tree does not always list it).
        j.sim.tap(200, 155)
    time.sleep(0.8)
    pq.type_text("tortoise")
    time.sleep(1.5)
    pq.shot("icon-after-search")
    cell = j.sim.wait(ident="iconPicker.symbol.tortoise", timeout=8)
    check(cell, f"no tortoise cell: {[e.ident for e in j.sim.find() if (e.ident or '').startswith('iconPicker')][:10]}")
    j.sim.tap_el(cell)
    _, took = r.wait_mac(lambda: by_key(ws["key"]).get("icon") == "tortoise" or None, "the icon on the Mac")
    out["mac_icon"] = by_key(ws["key"]).get("icon")
    out["s"] = round(took, 1)
    time.sleep(1.5)
    pq.shot("icon-after-row")
    return out


def folder(j, label):
    """Two workspaces in folder proj, one in proj2: View Options > Group by Folder puts them under a
    header per folder, as the Mac's cwd says; Group by None puts the list back."""
    r.close_mine()
    proj2 = pq.rsh(f"mkdir -p {pq.RBASE}/proj2 && cd {pq.RBASE}/proj2 && pwd").stdout.strip()
    r.make([f"{PREFIX}f1", f"{PREFIX}f2"])
    pq.RemoteMac().cmux("workspace", "create", "--name", f"{PREFIX}f3", "--cwd", proj2, json_out=True)
    t.until(lambda: f"{PREFIX}f3" in r.workspaces(), what="f3 on the Mac")
    out = {"mac_cwd": {n: (t.ws_tabs(w)[0][1].get("cwd") if t.ws_tabs(w) else None) for n, w in r.mine().items()}}
    j.back_to_list()
    menu = j.sim.wait(ident="workspaces.filter", timeout=6) or j.sim.wait(ident="workspaces.viewOptions", timeout=2)
    out["has_menu"] = bool(menu)
    if label == "before" and not menu:
        pq.shot("folder-before-toolbar")
        return out
    j.sim.tap_el(menu)
    time.sleep(1.2)
    out["menu"] = r.labels(j)
    pq.shot(f"folder-{label}-menu")
    if label == "before":
        out["has_rows"] = "Group by Folder" in out["menu"]
        # Outside the menu, low: a tap near the top lands on its Mac rows.
        j.sim.tap(60, 680)
        time.sleep(0.8)
        return out
    r.tap(j, "Group by Folder")
    time.sleep(1.5)
    r.list_row(j, f"{PREFIX}f3")
    out["headers"] = [e.ident for e in j.sim.find() if (e.ident or "").startswith("workspace.folder.")]
    pq.shot("folder-after-grouped")
    j.sim.tap_el(j.sim.wait(ident="workspaces.filter", timeout=6) or j.sim.wait(ident="workspaces.viewOptions", timeout=2))
    time.sleep(1.2)
    r.tap(j, "Group by None")
    time.sleep(1.5)
    out["headers_after_none"] = [e.ident for e in j.sim.find() if (e.ident or "").startswith("workspace.folder.")]
    pq.shot("folder-after-none")
    return out


def panes(j, label):
    """A workspace split right (two panes): Resize Pane + moves the divider 5% on the Mac; t3 > Move
    Tab to New Dock Column > Right docks it; pane 2 > Move Pane to New Workspace."""
    ws, key, name = p.seed("wsr", terminals=3)
    tabs = {tab.get("name"): tab["surface"] for _, tab in t.ws_tabs(ws)}
    pane = t.ws_tabs(ws)[0][0]
    t.mac_raw({"cmd": "move-tab-to-split", "surface": tabs["p2tabs-t2"], "pane": pane, "edge": "right"})
    p.wait_layout(key, lambda lay: len(lay["panes"]) == 2, "the seeded split")
    out = {"start": p.mac_layout(key)}
    t.open_ws(j, name)
    t.open_tab(j, "p2tabs-t1")
    p.open_panes(j)
    pq.shot(f"panes-{label}-page")
    out["has_resize"] = bool(j.sim.find(contains="Resize Pane"))
    if label == "before":
        e = j.sim.wait(ident=f"panes.tab.s{tabs['p2tabs-t3']}", timeout=6)
        if e:
            x, y = e.center
            j.sim.long_press(x, y, 1.0)
            time.sleep(1.2)
            out["tab_menu"] = r.labels(j)
            pq.shot("panes-before-tab-menu")
            p.close_menu(j)
        return out
    stepper = [e for e in j.sim.find() if (e.ident or "").startswith("panes.resize.")]
    check(stepper, "no Resize Pane stepper")
    inc = j.sim.wait(label="Increment", timeout=2) or j.sim.wait(contains=", Increment", timeout=4)
    check(inc, f"no Increment button: {r.labels(j)[:20]}")
    j.sim.tap_el(inc)
    out["resized"], took = p.wait_layout(key, lambda lay: "(0.55)" in lay["layout"], "the divider at 55% on the Mac")
    out["resize_s"] = round(took, 1)
    time.sleep(1)
    pq.shot("panes-after-resize")
    p.tab_menu(j, tabs["p2tabs-t3"], "Move Tab to New Dock Column", "Right")
    def docked():
        w = by_key(key)
        screen = next((s for s in w.get("screens", []) if s.get("active")), {})
        cols = [c for c in (screen.get("columns") or []) if c.get("dock")]
        return cols or None
    out["dock"], took = t.until(docked, what="a docked column on the Mac")
    out["dock_s"] = round(took, 1)
    time.sleep(1)
    pq.shot("panes-after-dock")
    lay = p.mac_layout(key)
    target = p.pane_of(lay, "p2tabs-t2")
    check(target, f"no pane with t2: {lay}")
    before = keys()
    p.pane_menu(j, target["id"], "Move Pane to New Workspace")
    newkey = new_key(before, "the pane's new workspace")
    moved = by_key(newkey)
    out["moved"] = {"key": newkey, "name": moved.get("name"), "tabs": [tab.get("name") for _, tab in t.ws_tabs(moved)],
                    "source_panes": len(p.mac_layout(key)["panes"]), "below_source": order_keys().index(newkey) == order_keys().index(key) + 1
                    if newkey in order_keys() and key in order_keys() else None}
    time.sleep(1.5)
    pq.shot("panes-after-move-pane")
    close_keys([newkey])
    return out


def screen(j, label):
    """A screen renamed "wsr-scr" in the project folder: Screens > its menu > Duplicate Screen. The
    Mac lists a second screen with the same name whose terminal is in the same folder."""
    ws, key, name = p.seed("wsrscr", terminals=1)
    first = ws["screens"][0]
    t.mac_raw({"cmd": "rename-screen", "screen": first["id"], "name": f"{PREFIX}scr"})
    out = {"start": [(s.get("id"), s.get("name")) for s in by_key(key)["screens"]]}
    t.open_ws(j, name)
    t.open_tab(j, "p2tabs-t1")
    p.open_page_menu(j)
    row = next((x for x in r.labels(j) if x.startswith("Screens")), None)
    check(row, "no Screens in the page menu")
    p.tap_row(j, row)
    time.sleep(1)
    e = j.sim.wait(ident=f"screens.menu.{first['id']}", timeout=8)
    check(e, "no screen menu")
    j.sim.tap_el(e)
    time.sleep(1.0)
    out["screen_menu"] = r.labels(j)
    pq.shot(f"screen-{label}-menu")
    if label == "before":
        out["has_duplicate"] = "Duplicate Screen" in out["screen_menu"]
        p.close_menu(j)
        return out
    p.tap_row(j, "Duplicate Screen")
    screens, took = t.until(lambda: (lambda s: s if len(s) == 2 and all(x.get("name") == f"{PREFIX}scr" for x in s) else None)(by_key(key)["screens"]),
                            what="a second screen named as the first")
    out["screens"] = [(s.get("id"), s.get("name")) for s in screens]
    copy = screens[1]
    cwd = [tab.get("cwd") for pane in copy.get("panes", []) for tab in pane.get("tabs", [])]
    out["copy_cwd"] = cwd
    out["source_cwd"] = [tab.get("cwd") for pane in first.get("panes", []) for tab in pane.get("tabs", [])]
    out["s"] = round(took, 1)
    time.sleep(2)
    pq.shot("screen-after-duplicate")
    return out


def usage(j, label):
    """Row 9 check, Mac side only: what `machine-usage` (on the phone's lane) returns on this Mac."""
    return {"machine_usage": t.mac_raw({"cmd": "machine-usage"})}


FLOWS = {"place": place, "merge": merge, "groups": groups, "icon": icon, "folder": folder, "panes": panes, "screen": screen,
         "usage": usage}


def run(name, label):
    sim, mac, j = pq.ctx()
    if name != "usage":
        try:
            r.fresh(j)
        except Fail:
            # The list was left on another Mac: back to the rig Mac (Filter > it), then the list.
            j.choose_mac()
            r.fresh(j)
    pq.rec_start(f"{name}-{label}")
    try:
        out = FLOWS[name](j, label)
    finally:
        pq.rec_stop()
    os.makedirs(pq.ART, exist_ok=True)
    json.dump(out, open(os.path.join(pq.ART, f"{name}-{label}.json"), "w"), indent=2)
    return out
