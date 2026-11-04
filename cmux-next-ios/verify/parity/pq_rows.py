"""Menu row parity flows (feat-cmux-next-ios-menu-rows-parity, cmux#25834 slices A, B and C):
Close Tabs to the Left / Right; Close Other Workspaces in Group, Close All in Group, Close Other
Groups, Close All Workspaces; Move Workspace to Top / Bottom and Sort Workspaces; Remove All
Workspace Colors; Collapse Others / Collapse All / Expand All groups; Retry with another model;
the diff viewer's Next / Previous Hunk and Search; Open Address in New Tab.

Same rig as pq.py and pq_tabs.py: the phone app in ONE headless simulator, the real tagged
cmux-next Mac app (rmac.py), the real link between them. Every action under test is done on the
phone; after each one the Mac's state is read back from the rig app's own daemon socket
(`list-workspaces`, `list-personal`) or acpmux socket (`_acpmux/sessions`). Setup (seeding
workspaces, groups, colors, a Mac-started Claude chat) is done on the Mac side.

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    . ~/cmux-next-ios-e2e/rows/env.sh && python3 -c 'import pq_rows as r; print(r.run("tabs", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import shlex
import time

import pq
import pq_tabs as t
from journey import Fail, check

PREFIX = "rows-"


# ---------------------------------------------------------------- the Mac side

def v2(operation, params=None):
    """A cmux.protocol/2 request on the rig Mac's daemon (setup and reads)."""
    fields = dict(params or {})
    fields.setdefault("machine", "current")
    fields.setdefault("session", "current")
    line = json.dumps({"protocol": "cmux.protocol/2", "type": "request", "id": "1", "operation": operation, "params": fields,
                       "idempotency_key": f"pq-rows-{operation}-{time.time_ns()}"})
    r = pq.rsh(f"python3 -c {shlex.quote(_V2)} {shlex.quote(t.TAG)} {shlex.quote(line)}", timeout=60)
    check(r.returncode == 0, f"daemon {operation}: {r.stderr.strip()[:300]}")
    reply = json.loads(r.stdout)
    check(reply.get("ok", True), f"daemon {operation}: {reply.get('error')}")
    return reply


# The v2 envelope wants a string id (t.mac_raw sends the number 1).
_V2 = t._DAEMON.replace('json.loads(line).get("id") == 1', 'json.loads(line).get("id") == "1"')


def personal():
    data = t.mac_raw({"cmd": "list-personal"})
    return data.get("data", data)


def workspaces():
    """The Mac's workspaces: {name: ws}."""
    return {(w.get("title") or w.get("name")): w for w in t.mac_tree().get("workspaces", [])}


def mine():
    return {n: w for n, w in workspaces().items() if (n or "").startswith(PREFIX)}


def order(names=None):
    """The Mac's personal order of this flow's workspaces (titles)."""
    tree = t.mac_tree()
    registry = tree.get("registry_id")
    rows = sorted(personal().get("workspaces", []), key=lambda r: r.get("index", 0))
    place = {r["workspace_key"]: i for i, r in enumerate(rows) if r.get("session_id") == registry}
    listed = [(w.get("title") or w.get("name"), w.get("key")) for w in tree.get("workspaces", [])]
    listed = [(n, k) for n, k in listed if (names is None and (n or "").startswith(PREFIX)) or (names and n in names)]
    return [n for n, k in sorted(listed, key=lambda nk: (nk[1] not in place, place.get(nk[1], 0)))]


def groups():
    """The person's groups: {name: {id, collapsed, pinned, members}}."""
    data = personal()
    tree = t.mac_tree()
    by_key = {w.get("key"): (w.get("title") or w.get("name")) for w in tree.get("workspaces", [])}
    out = {}
    for g in data.get("groups", []):
        members = [by_key.get(r["workspace_key"]) for r in data.get("workspaces", []) if r.get("group") == g["id"]]
        out[g.get("name")] = {"id": g["id"], "collapsed": g.get("collapsed"), "pinned": g.get("pinned"),
                              "members": sorted(m for m in members if m)}
    return out


def make(names, terminals=1):
    """Workspaces named `names` on the Mac, in the rig's project folder (setup)."""
    proj = pq.rsh(f"mkdir -p {t.PROJ} && cd {t.PROJ} && pwd").stdout.strip()
    for name in names:
        if name not in workspaces():
            pq.RemoteMac().cmux("workspace", "create", "--name", name, "--cwd", proj, json_out=True)
    t.until(lambda: all(n in workspaces() for n in names), timeout=30, what=f"{names} on the Mac")
    return [workspaces()[n] for n in names]


def group(name, members, color="red"):
    """A personal group holding `members` (setup, as the Mac's Move Workspace to New Group)."""
    made = v2("workspace_group.create", {"name": name, "color": color, "room": "default"})
    result = made.get("result", made)
    gid = (result.get("value") or result).get("id")
    check(gid, f"no group id in {made}")
    for m in members:
        v2("workspace.place", {"workspace": workspaces()[m]["resource_id"], "group": gid})
    return gid


def close_mine():
    """Setup: closes this lane's earlier workspaces and deletes its groups."""
    for name, w in mine().items():
        t.mac_raw({"cmd": "close-workspace", "key": w["key"], "end_terminals": True})
    for name, g in groups().items():
        if (name or "").startswith(PREFIX):
            v2("workspace_group.delete", {"workspace_group": g["id"]})


def wait_mac(fn, what, timeout=25):
    return t.until(fn, timeout=timeout, what=what)


# ---------------------------------------------------------------- the phone side

def labels(j):
    return [e.label for e in j.sim.find() if e.label and e.kind in ("Button", "PopUpButton", "MenuItem")]


def tap(j, label, timeout=6, contains=False, bottom=775):
    for _ in range(4):
        e = (j.sim.wait(contains=label, kind="Button", timeout=timeout) if contains
             else j.sim.wait(label=label, kind="Button", timeout=timeout) or j.sim.wait(label=label, timeout=1))
        # A long context menu ends above the tab bar (about y 770) and scrolls inside itself.
        if e and e.frame[1] + e.frame[3] < bottom:
            j.sim.tap_el(e)
            time.sleep(1.0)
            return
        if e:
            j.sim.swipe(140, 680, 140, 380, 0.4)
            time.sleep(0.8)
            timeout = 2
            continue
        break
    raise Fail(f"no {label!r}; buttons: {labels(j)[:30]}")


def list_row(j, title, timeout=40):
    j.back_to_list()
    e = j.sim.wait(prefix=title, kind="Button", timeout=timeout)
    if not e:
        j.sim.drag(201, 300, 201, 650, 0.4, 20, 0.2)
        e = j.sim.wait(prefix=title, kind="Button", timeout=timeout)
    check(e, f"no row {title!r} on the phone")
    for _ in range(6):
        if 120 < e.frame[1] and e.frame[1] + e.frame[3] < 760:
            break
        j.sim.drag(201, 650 if e.frame[1] > 400 else 300, 201, 300 if e.frame[1] > 400 else 650, 0.5, 30, 0.4)
        time.sleep(0.8)
        e = j.sim.wait(prefix=title, kind="Button", timeout=5) or e
    return e


def hold(j, e):
    x, y = e.center
    j.sim.long_press(x, y, 1.2)
    time.sleep(1.3)


def row_menu(j, title):
    """Holds a workspace row until its menu shows (a hold the loaded simulator dropped is tried again)."""
    for _ in range(4):
        hold(j, list_row(j, title))
        if j.sim.find(label="Close Workspace", kind="Button") or j.sim.find(label="Rename", kind="Button"):
            break
        dismiss(j)
    return labels(j)


def group_menu(j, gid):
    for _ in range(4):
        hold(j, group_header(j, gid))
        if j.sim.find(label="Rename Group…", kind="Button"):
            break
        dismiss(j)
    return labels(j)


def group_header(j, gid, timeout=20):
    j.back_to_list()
    e = j.sim.wait(ident=f"workspace.group.{gid}", timeout=timeout)
    check(e, f"no group header {gid}")
    return e


def dismiss(j):
    j.sim.tap(200, 120)
    time.sleep(0.8)


def phone_order(j, titles):
    ys = {}
    for n in titles:
        e = j.sim.find(prefix=n, kind="Button")
        if e:
            ys[n] = e[0].frame[1]
    return sorted(ys, key=ys.get)


def confirm(j, button):
    q = j.sim.wait(contains="workspace", timeout=6)
    check(q, "no question before the close")
    question = [e.label for e in j.sim.find(contains="Close ") if e.label and "?" in e.label]
    message = [e.label for e in j.sim.find(contains="close on") if e.label]
    tap(j, button)
    return {"question": question[:1], "message": message[:1]}


# ---------------------------------------------------------------- flows

def tabs(j, label):
    """Close Tabs to the Left on t2 (t1 closes), then Close Tabs to the Right on t2 (t3, t4 close)."""
    ws = t.seed("rows-tabs", terminals=4)
    key = ws["key"]
    names = lambda: [tab.get("name") or tab.get("title") for _, tab in t.ws_tabs(t.mac_workspace(key=key))]
    out = {"start": names()}
    t.open_ws(j, ws["name"])
    pq.open_grid(j)
    hold(j, t.card(j, "p2tabs-t2"))
    out["card_menu"] = labels(j)
    pq.shot(f"tabs-{label}-menu")
    if label == "before":
        out["has_rows"] = "Close Tabs to the Left" in out["card_menu"]
        dismiss(j)
        return out
    tap(j, "Close Tabs to the Left")
    out["left"], took = wait_mac(lambda: (lambda n: n if n == ["p2tabs-t2", "p2tabs-t3", "p2tabs-t4"] else None)(names()), "t1 closed on the Mac")
    out["left_s"] = round(took, 1)
    time.sleep(1)
    pq.shot("tabs-after-left")
    hold(j, t.card(j, "p2tabs-t2"))
    pq.shot("tabs-after-menu2")
    tap(j, "Close Tabs to the Right")
    out["right"], took = wait_mac(lambda: (lambda n: n if n == ["p2tabs-t2"] else None)(names()), "t3 and t4 closed on the Mac")
    out["right_s"] = round(took, 1)
    time.sleep(1)
    pq.shot("tabs-after-right")
    return out


def closes(j, label):
    """Two groups of two (A: a1 a2, B: b1 b2) and one loose workspace. Close Other Workspaces in
    Group on a1 (a2 closes); Close Other Groups on A (B's workspaces close); Close All in Group on A
    (a1 closes); Close All Workspaces on the loose one (every workspace of the Mac, never Home)."""
    close_mine()
    names = [f"{PREFIX}a1", f"{PREFIX}a2", f"{PREFIX}b1", f"{PREFIX}b2", f"{PREFIX}loose"]
    make(names)
    ga = group(f"{PREFIX}A", names[:2], "red")
    gb = group(f"{PREFIX}B", names[2:4], "green")
    out = {"start": {"groups": groups(), "workspaces": sorted(workspaces())}}
    out["row_menu"] = row_menu(j, names[0])
    pq.shot(f"closes-{label}-row-menu")
    out["close_rows"] = [(e.label, e.kind, [int(x) for x in e.frame]) for e in j.sim.find(contains="Close")]
    folder = [e for e in j.sim.find(label="Close", kind="Button")]
    if folder:
        # The menu scrolls inside itself: drag from its last visible row (Close Workspace) upward.
        for _ in range(3):
            last = j.sim.find(label="Close Workspace", kind="Button")
            if not last or folder[0].frame[1] + 10 < (last[0].frame[1] + last[0].frame[3] + 20) and \
                    j.sim.ocr_find("Close", timeout=0) and len([o for o in j.sim.ocr() if o[4].strip() == "Close"]) > 0:
                break
            y = last[0].center[1]
            j.sim.swipe(140, y, 140, max(140, y - 260), 0.5)
            time.sleep(0.8)
            folder = [e for e in j.sim.find(label="Close", kind="Button")]
        j.sim.tap_el(folder[0])
        time.sleep(1.0)
    out["close_folder"] = labels(j)
    pq.shot(f"closes-{label}-row-close")
    if label == "before":
        out["has_rows"] = "Close Other Workspaces in Group" in out["close_folder"]
        dismiss(j)
        out["group_menu"] = group_menu(j, ga)
        pq.shot("closes-before-group-menu")
        dismiss(j)
        return out
    tap(j, "Close Other Workspaces in Group")
    out["in_group_ask"] = confirm(j, "Close Workspace")
    out["in_group"], _ = wait_mac(lambda: (lambda w: sorted(w) if names[1] not in w and names[0] in w else None)(mine()), "a2 closed")
    pq.shot("closes-after-in-group")
    out["group_menu"] = group_menu(j, ga)
    pq.shot("closes-after-group-menu")
    tap(j, "Close Other Groups")
    out["other_groups_ask"] = confirm(j, "Close Workspaces")
    out["other_groups"], _ = wait_mac(lambda: (lambda w: sorted(w) if not any(n in w for n in names[2:4]) else None)(mine()),
                                      "B's workspaces closed")
    out["groups_after_other"] = groups()
    pq.shot("closes-after-other-groups")
    group_menu(j, ga)
    tap(j, "Close All in Group")
    out["all_in_group_ask"] = confirm(j, "Close Workspace")
    out["all_in_group"], _ = wait_mac(lambda: (lambda w: sorted(w) if names[0] not in w else None)(mine()), "a1 closed")
    pq.shot("closes-after-all-in-group")
    before_all = sorted(workspaces())
    row_menu(j, names[4])
    tap(j, "Close")
    pq.shot("closes-after-close-folder")
    tap(j, "Close All Workspaces")
    out["all_ask"] = confirm(j, "Close Workspaces")
    out["before_all"] = before_all
    out["all"], _ = wait_mac(lambda: (lambda w: sorted(w) if not mine() and len(w) <= 1 else None)(workspaces()), "every workspace closed", timeout=40)
    time.sleep(1.5)
    pq.shot("closes-after-all")
    return out


def ordering(j, label):
    """Four loose workspaces in the order c, a, d, b. Move b to Top; move c to Bottom; Sort by Name."""
    close_mine()
    names = [f"{PREFIX}c", f"{PREFIX}a", f"{PREFIX}d", f"{PREFIX}b"]
    make(names)
    tree = t.mac_tree()
    registry = tree.get("registry_id")
    rows = personal().get("workspaces", [])
    base = len(rows) + 10
    for i, n in enumerate(names):
        t.mac_raw({"cmd": "set-personal-workspace", "session_id": registry, "workspace_key": workspaces()[n]["key"], "index": base + i})
    wait_mac(lambda: order() == names or None, "the seeded order")
    out = {"start": order()}
    out["row_menu"] = row_menu(j, names[3])
    tap(j, "Move")
    out["move_folder"] = labels(j)
    pq.shot(f"order-{label}-move")
    if label == "before":
        out["has_rows"] = "Move Workspace to Top" in out["move_folder"]
        dismiss(j)
        return out
    tap(j, "Move Workspace to Top")
    out["top"], took = wait_mac(lambda: (lambda o: o if o[0] == names[3] else None)(order()), "b at the top")
    out["top_s"] = round(took, 1)
    row_menu(j, names[0])
    tap(j, "Move")
    tap(j, "Move Workspace to Bottom")
    out["bottom"], _ = wait_mac(lambda: (lambda o: o if o[-1] == names[0] else None)(order()), "c at the bottom")
    pq.shot("order-after-bottom")
    row_menu(j, names[1])
    tap(j, "Move")
    tap(j, "Sort Workspaces")
    pq.shot("order-after-sort-menu")
    tap(j, "Sort Workspaces by Name")
    want = sorted(names)
    out["sorted"], took = wait_mac(lambda: (lambda o: o if o == want else None)(order()), "sorted by name", timeout=40)
    out["sorted_s"] = round(took, 1)
    time.sleep(1.5)
    j.back_to_list()
    out["phone_order"] = phone_order(j, names)
    pq.shot("order-after-sorted")
    return out


def colors(j, label):
    """Two colored workspaces; Appearance > Remove All Workspace Colors."""
    close_mine()
    names = [f"{PREFIX}red", f"{PREFIX}blue", f"{PREFIX}plain"]
    make(names)
    t.mac_raw({"cmd": "set-workspace-metadata", "key": workspaces()[names[0]]["key"], "color": "red"})
    t.mac_raw({"cmd": "set-workspace-metadata", "key": workspaces()[names[1]]["key"], "color": "blue"})
    col = lambda: {n: w.get("color") for n, w in mine().items()}
    out = {"start": col()}
    time.sleep(2)
    row_menu(j, names[2])
    tap(j, "Appearance")
    out["appearance"] = labels(j)
    pq.shot(f"colors-{label}-appearance")
    if label == "before":
        out["has_row"] = "Remove All Workspace Colors" in out["appearance"]
        dismiss(j)
        return out
    tap(j, "Remove All Workspace Colors")
    out["after"], took = wait_mac(lambda: (lambda c: c if not any(c.values()) else None)(col()), "no colors on the Mac")
    out["after_s"] = round(took, 1)
    time.sleep(1)
    j.back_to_list()
    pq.shot("colors-after-list")
    return out


def collapse(j, label):
    """Groups X and Y, both open. Collapse All Groups, Expand All Groups, then Collapse Others on X."""
    close_mine()
    names = [f"{PREFIX}x1", f"{PREFIX}y1"]
    make(names)
    gx = group(f"{PREFIX}X", names[:1], "purple")
    group(f"{PREFIX}Y", names[1:], "cyan")
    folded = lambda: {n: g["collapsed"] for n, g in groups().items() if n.startswith(PREFIX)}
    out = {"start": folded()}
    out["group_menu"] = group_menu(j, gx)
    pq.shot(f"collapse-{label}-menu")
    if label == "before":
        out["has_options"] = "Options" in out["group_menu"]
        dismiss(j)
        return out
    tap(j, "Options")
    out["options"] = labels(j)
    pq.shot("collapse-after-options")
    tap(j, "Collapse All Groups")
    out["all"], _ = wait_mac(lambda: (lambda f: f if all(f.values()) else None)(folded()), "both collapsed")
    pq.shot("collapse-after-all")
    group_menu(j, gx)
    tap(j, "Options")
    tap(j, "Expand All Groups")
    out["expanded"], _ = wait_mac(lambda: (lambda f: f if not any(f.values()) else None)(folded()), "both expanded")
    group_menu(j, gx)
    tap(j, "Options")
    tap(j, "Collapse Others")
    out["others"], _ = wait_mac(lambda: (lambda f: f if f.get(f"{PREFIX}Y") and not f.get(f"{PREFIX}X") else None)(folded()),
                                "Y collapsed, X open")
    time.sleep(1)
    pq.shot("collapse-after-others")
    return out


# ---------------------------------------------------------------- chats (Mac-started Claude chat)

_ACPMUX = r"""
import glob, json, os, socket, sys
paths = sorted(glob.glob(os.path.expanduser(sys.argv[1])), key=os.path.getmtime)
s = socket.socket(socket.AF_UNIX); s.connect(paths[-1]); f = s.makefile("rw")
f.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1,
        "clientInfo": {"name": "pq_rows", "version": "1"}, "clientCapabilities": {}}}) + "\n")
f.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": sys.argv[2], "params": json.loads(sys.argv[3])}) + "\n"); f.flush()
while True:
    m = json.loads(f.readline())
    if m.get("id") == 2:
        print(json.dumps(m.get("result", m))); break
"""


def acpmux(method, params=None, timeout=60):
    glob_ = os.environ.get("PQ_ACPMUX_SOCK", "")
    check(glob_, "PQ_ACPMUX_SOCK is not set")
    r = pq.rsh(f"python3 -c {shlex.quote(_ACPMUX)} {shlex.quote(glob_)} {shlex.quote(method)} {shlex.quote(json.dumps(params or {}))}",
               timeout=timeout)
    check(r.returncode == 0, f"acpmux {method}: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def session(sid):
    return next((s for s in acpmux("_acpmux/sessions").get("sessions", []) if s.get("sessionId") == sid), None)


def chat_seed():
    """Rig setup on the Mac: a workspace, a Claude chat started on the Mac in its folder that edited
    a file in two places (for the diff), shown as a tab of the workspace."""
    st = pq.load().get("rows_chat")
    if st and t.mac_workspace(key=st["key"]):
        return st
    ws = t.seed("rows-chat", terminals=1)
    folder = pq.rsh(f"cd {t.PROJ} && pwd -P").stdout.strip()
    lines = "\\n".join(f"line {n}" for n in range(1, 41))
    pq.rsh(f"printf '{lines}\\n' > {t.PROJ}/notes.txt")
    acpmux("acp.trust.set", {"cwd": folder, "level": "trusted"})
    made = acpmux("session/new", {"cwd": folder, "mcpServers": [], "_meta": {"acpmux": {"harness": "claude", "policy": "approve-all"}}})
    sid = made["sessionId"]
    acpmux("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text":
           "In notes.txt, replace the line 'line 5' with 'line five' and the line 'line 30' with 'line thirty'. Use your edit tool, then reply done."}]},
           timeout=400)
    pane = t.ws_tabs(t.mac_workspace(key=ws["key"]))[0][0]
    host = pq.rsh("ps eww -o command -p $(pgrep -f 'menu-rows-parity.app/Contents/Resources/bin/cmux-mobile-host') "
                  "| tr ' ' '\\n' | sed -n 's/^CMUX_MOBILE_AGENT_TAB_HOST=//p'").stdout.strip()
    check(host, "the rig Mac's agent tab host")
    t.mac_raw({"cmd": "new-conversation-tab", "pane": pane, "agent_session": {"host": host, "harness": "claude", "session": sid}})
    st = {"name": ws["name"], "key": ws["key"], "session": sid}
    full = pq.load()
    full["rows_chat"] = st
    pq.save(full)
    return st


def open_chat(j, st):
    t.open_ws(j, st["name"])
    pq.open_grid(j)
    cards = [e for e in j.sim.find(suffix=", tab") if not (e.label or "").startswith("p2tabs-t")]
    check(cards, "no chat card")
    j.sim.tap_el(cards[0])
    time.sleep(3)


def retry(j, label):
    """The last answer's More menu: Retry with another model > another model. acpmux refuses the
    model change for a Claude chat the Mac started (D13): the chat shows that reason and no new
    turn runs on the Mac."""
    st = chat_seed()
    s0 = session(st["session"]) or {}
    out = {"start": {"model": s0.get("model"), "turns": s0.get("turnCount") or s0.get("turns")}}
    open_chat(j, st)
    more = [e for e in j.sim.find(label="More") if e.kind in ("Button", "PopUpButton")]
    check(more, f"no More button on the answer: {labels(j)}")
    j.sim.tap_el(more[-1])
    time.sleep(1.2)
    out["more_menu"] = labels(j)
    pq.shot(f"retry-{label}-more")
    if label == "before":
        out["has_row"] = "Retry with another model" in out["more_menu"]
        dismiss(j)
        return out
    tap(j, "Retry with another model")
    out["models"] = labels(j)
    pq.shot("retry-after-models")
    current = [e for e in j.sim.find() if e.kind in ("Button", "MenuItem") and e.label and e.frame[1] > 100]
    pick = next((e for e in current if e.label and "Sonnet" in e.label), None) or next(
        (e for e in current if e.label and "Haiku" in e.label), None)
    check(pick, f"no other model to pick: {out['models']}")
    out["picked"] = pick.label
    j.sim.tap_el(pick)
    time.sleep(3)
    t0 = time.time()
    seen = None
    while time.time() - t0 < 30 and not seen:
        seen = [e.label for e in j.sim.find(contains="permissions") if e.label] or \
               [e.label for e in j.sim.find(contains="refused") if e.label]
        time.sleep(0.5)
    out["refusal"] = seen
    pq.shot("retry-after-refusal")
    s1 = session(st["session"]) or {}
    out["end"] = {"model": s1.get("model"), "turns": s1.get("turnCount") or s1.get("turns")}
    return out


def diff(j, label):
    """Agent Edits > notes.txt: Next Hunk twice, Previous Hunk, then Search in File "thirty"."""
    st = chat_seed()
    open_chat(j, st)
    # The answer's edited-files card: its notes.txt row opens the file's diff.
    f = j.sim.wait(prefix="notes.txt", kind="Button", timeout=10)
    check(f, f"no notes.txt row in the edited files card: {labels(j)}")
    j.sim.tap_el(f)
    time.sleep(2)
    out = {"buttons": labels(j)}
    pq.shot(f"diff-{label}-file")
    if label == "before":
        out["has_hunks"] = "Next Hunk" in out["buttons"]
        out["has_search"] = "Search in File" in out["buttons"]
        return out
    visible = lambda text: bool(j.sim.find(contains=text))
    tap(j, "Next Hunk", bottom=900)
    time.sleep(1.2)
    pq.shot("diff-after-hunk1")
    out["hunk1_line_five"] = visible("line five")
    tap(j, "Next Hunk", bottom=900)
    time.sleep(1.2)
    pq.shot("diff-after-hunk2")
    out["hunk2_line_thirty"] = visible("line thirty")
    tap(j, "Previous Hunk", bottom=900)
    time.sleep(1.2)
    out["back_line_five"] = visible("line five")
    tap(j, "Search in File", bottom=900)
    time.sleep(0.8)
    pq.type_text("thirty")
    time.sleep(1.2)
    out["count"] = [e.label for e in j.sim.find(ident="diff.search.count")] or [e.label for e in j.sim.find(contains=" of ")]
    pq.shot("diff-after-search")
    return out


def address(j, label):
    """A browser tab at example.com; type iana.org in its address bar; "Open Address in New Tab".
    The Mac gets a second browser tab at that address; the first keeps its page."""
    ws = t.seed("rows-browser", terminals=1)
    key = ws["key"]
    browsers = lambda: [tab for _, tab in t.ws_tabs(t.mac_workspace(key=key)) if tab.get("kind") == "browser"]
    t.open_ws(j, ws["name"])
    pq.plus_menu(j, "New Browser Tab")
    pq.wait_opened(j, timeout=60)
    addr = j.sim.wait(prefix="Address", kind="Button", timeout=10)
    check(addr, "no address field")
    j.sim.tap_el(addr)
    time.sleep(0.8)
    pq.type_text("https://example.com\n")
    time.sleep(4)
    out = {"start": [b.get("url") for b in browsers()]}
    addr = j.sim.wait(prefix="Address", kind="Button", timeout=10)
    j.sim.tap_el(addr)
    time.sleep(0.8)
    pq.type_text("www.iana.org")
    time.sleep(1.2)
    out["suggestions"] = labels(j)
    pq.shot(f"address-{label}-editing")
    if label == "before":
        out["has_row"] = any((x or "").startswith("Open Address in New Tab") for x in out["suggestions"])
        return out
    e = j.sim.wait(ident="address.openInNewTab", timeout=3) or j.sim.wait(contains="Open Address in New Tab", timeout=5)
    check(e, "no Open Address in New Tab row")
    j.sim.tap_el(e)
    out["after"], took = wait_mac(lambda: (lambda b: [x.get("url") for x in b] if len(b) == 2 else None)(browsers()),
                                  "a second browser tab on the Mac", timeout=40)
    out["after_s"] = round(took, 1)
    time.sleep(4)
    pq.shot("address-after-new-tab")
    out["address_now"] = [x.label for x in j.sim.find(prefix="Address", kind="Button")]
    return out


FLOWS = {"tabs": tabs, "closes": closes, "order": ordering, "colors": colors, "collapse": collapse,
         "retry": retry, "diff": diff, "address": address}


def fresh(j):
    """Each flow starts on the Workspaces list: the app relaunched (it reconnects to the rig Mac
    over the real link), whatever page the last flow left open."""
    j.sim.launch(pq.BUNDLE)
    time.sleep(4)
    seed = pq.load()["ws_name"]
    for _ in range(12):
        if j.sim.find(prefix=seed, kind="Button"):
            return
        menu_open = [e for e in j.sim.find(kind="Button") if e.label in ("Done",) and e.frame[1] < 120]
        back = [e for e in j.sim.find(label="Back", kind="Button") if e.frame[1] > 760] or \
               [e for e in j.sim.find(label="Workspaces", kind="Button") if e.frame[1] < 120]
        tabbar = j.sim.find(label="Workspaces", kind="RadioButton")
        if menu_open:
            j.sim.tap_el(menu_open[0])
        elif back:
            j.sim.tap_el(back[0])
        elif tabbar:
            j.sim.tap_el(tabbar[0])
        time.sleep(1.5)
    raise Fail("could not get to the Workspaces list after a relaunch")


def run(name, label):
    sim, mac, j = pq.ctx()
    fresh(j)
    pq.rec_start(f"{name}-{label}")
    try:
        out = FLOWS[name](j, label)
    finally:
        pq.rec_stop()
    os.makedirs(pq.ART, exist_ok=True)
    json.dump(out, open(os.path.join(pq.ART, f"{name}-{label}.json"), "w"), indent=2)
    return out
