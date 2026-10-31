"""Parity round 2, workspace lane (feat-cnx-ios-p2ws): end-to-end flows on the rig.

Each flow does the action on the phone (the app in this agent's own simulator, taps
through axe), proves the Mac changed (the rig Mac's own state, read over ssh), and
records a video. Only workspaces these flows created are touched; their names start
with `p2ws-`.

    PQ_SIM=cmux-mobile-p2-ws PQ_STATE=~/cmux-next-ios-e2e/p2ws-state.json PQ_RAW=~/cmux-next-ios-e2e/p2ws-raw \\
        python3 -c 'import pq_ws; pq_ws.run_all()'
    python3 -c 'import pq_ws; pq_ws.run("pin_color_order")'

Flows: pin_color_order, mark_unread, bulk_close, open_folder, feed_clear_all, trust_steps.
Videos: $PQ_RAW/ws-<flow>.mp4.
"""
import json
import os
import shlex
import time
import traceback

import pq
from pq import Fail, RemoteMac, check, ctx, load, log, rec_start, rec_stop, rsh

PREFIX = "p2ws-"


# ---------------------------------------------------------------- the Mac side

def mac():
    return RemoteMac()


_SOCKET_CLIENT = r"""
import glob, json, os, socket, sys
sys.path.insert(0, 'e2e'); sys.path.insert(0, '.')
import rmac
tag = rmac.mac().tag
paths = glob.glob(os.path.join(os.environ.get('TMPDIR', '/tmp'), 'cmux-tui-%d' % os.getuid(), 'cmux-app-%s.sock' % tag))
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(paths[0])
line = sys.argv[1]
want = json.loads(line)['id']
# Without these capabilities the daemon shows chat tabs as browser tabs.
s.sendall(json.dumps({'id': 'p2ws-hello', 'cmd': 'set-client-info', 'name': 'pq_ws', 'kind': 'cli', 'capabilities': ['conversation-tabs-v1', 'agent-session-tabs-v1']}).encode() + b'\n')
s.sendall(line.encode() + b'\n')
buf = b''
while True:
    chunk = s.recv(1 << 20)
    if not chunk: break
    buf += chunk
    while b'\n' in buf:
        one, buf = buf.split(b'\n', 1)
        try: obj = json.loads(one)
        except ValueError: continue
        if obj.get('id') == want:
            print(json.dumps(obj)); sys.exit(0)
"""


def _socket(request):
    """One line to the rig Mac's own daemon session socket (read only), its reply as JSON."""
    line = json.dumps(request)
    r = rsh(f"cd {pq.RBASE} && python3 -c {shlex.quote(_SOCKET_CLIENT)} {shlex.quote(line)}", timeout=120)
    out = (r.stdout or "").strip().splitlines()
    if not out:
        raise RuntimeError(f"daemon {request.get('cmd') or request.get('operation')}: {(r.stderr or '').strip()[-400:]}")
    return json.loads(out[-1])


def daemon(request):
    """A control-protocol line to the rig Mac's daemon."""
    return _socket(request)


def operation(name, params=None):
    """A cmux.protocol/2 read on the rig Mac's daemon."""
    fields = dict(params or {})
    fields.setdefault("machine", "current")
    fields.setdefault("session", "current")
    return _socket({"protocol": "cmux.protocol/2", "type": "request", "id": "p2ws-op", "operation": name, "params": fields})


def mac_workspaces():
    """The rig Mac's workspaces in its daemon's order: [{key, title, color, pinned, marked_unread, resource_id}]."""
    reply = daemon({"cmd": "list-workspaces", "id": "p2ws"})
    data = reply.get("data") or reply
    out = []
    for ws in data.get("workspaces", []):
        out.append({
            "key": ws.get("key"), "title": ws.get("title") or ws.get("name"), "color": ws.get("color"),
            "pinned": ws.get("pinned"), "marked_unread": ws.get("marked_unread"), "resource_id": ws.get("resource_id"),
            "registry_id": data.get("registry_id"),
        })
    return out


def mac_workspace(title):
    return next((w for w in mac_workspaces() if w["title"] == title), None)


def mac_order():
    """The Mac's sidebar order of its own workspaces' titles (personal order, else the daemon's)."""
    workspaces = mac_workspaces()
    personal = daemon({"cmd": "list-personal", "id": "p2ws"})
    rows = ((personal.get("data") or {}).get("workspaces")) if personal.get("ok") else None
    if not rows:
        return [w["title"] for w in workspaces]
    registry = workspaces[0]["registry_id"] if workspaces else None
    place = {r["workspace_key"]: i for i, r in enumerate(sorted(rows, key=lambda r: r.get("index", 0))) if r.get("session_id") == registry}
    return [w["title"] for w in sorted(workspaces, key=lambda w: (w["key"] not in place, place.get(w["key"], 0)))]


def mac_pinned_titles():
    """Titles the Mac shows pinned: tiles of its pinned section, plus legacy flags."""
    workspaces = mac_workspaces()
    by_ref = {f"{w['registry_id']}:{w['resource_id']}": w["title"] for w in workspaces if w["resource_id"]}
    layout = operation("sidebar_layout.get")
    snapshot = layout.get("result", layout)
    titles = set()
    for section in snapshot.get("sections", []) if isinstance(snapshot, dict) else []:
        if section.get("id") == "sec_pinned":
            for item in section.get("items", []):
                ref = item.get("ref", {})
                if ref.get("kind") == "workspace" and ref.get("value") in by_ref:
                    titles.add(by_ref[ref["value"]])
    return titles | {w["title"] for w in workspaces if w["pinned"]}


def mac_notifications():
    reply = daemon({"cmd": "list-notifications", "id": "p2ws", "limit": 100})
    return ((reply.get("data") or {}).get("notifications")) or []


def proj_dir(name):
    path = rsh(f"mkdir -p ~/cmux-next-ios-e2e/{name} && cd ~/cmux-next-ios-e2e/{name} && printf '# {name}\\n' > README.md && pwd").stdout.strip()
    check(path, f"could not make the folder {name} on the rig Mac")
    return path


def make_workspaces(names, folder="p2ws-proj"):
    """Workspaces for a flow, made on the Mac (setup, not the action under test)."""
    path = proj_dir(folder)
    for name in names:
        if not mac_workspace(name):
            mac().cmux("workspace", "create", "--name", name, "--cwd", path, json_out=True)
    deadline = time.time() + 20
    while time.time() < deadline and not all(mac_workspace(n) for n in names):
        time.sleep(0.5)
    check(all(mac_workspace(n) for n in names), f"the Mac never listed {names}")


def close_on_mac(names):
    """Cleanup: only this lane's own workspaces."""
    for name in names:
        assert name.startswith(PREFIX)
        w = mac_workspace(name)
        if w and w["key"]:
            daemon({"cmd": "close-workspace", "id": "p2ws", "key": w["key"]})


def wait_mac(pred, what, timeout=20):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = pred()
        if last:
            return last
        time.sleep(0.5)
    raise Fail(f"the Mac never showed {what}")


# ---------------------------------------------------------------- the phone side

def row(j, title, timeout=30):
    j.back_to_list()
    e = j.sim.wait(prefix=title, kind="Button", timeout=timeout)
    if not e:
        # Pull to refresh once (the list can lag a Mac-side setup by a moment).
        j.sim.drag(201, 300, 201, 650, 0.4, 20, 0.2)
        e = j.sim.wait(prefix=title, kind="Button", timeout=timeout)
    check(e, f"no row {title!r} on the phone")
    # Under the tab bar: scroll it up into the middle of the list.
    for _ in range(6):
        if e.frame[1] + e.frame[3] < 760:
            break
        j.sim.drag(201, 650, 201, 300, 0.5, 30, 0.4)
        time.sleep(0.8)
        e = j.sim.wait(prefix=title, kind="Button", timeout=5) or e
    return e


def row_menu(j, title):
    """Holds a workspace row: its context menu."""
    e = row(j, title)
    x, y = e.center
    j.sim.long_press(x, y, 1.2)
    time.sleep(1.2)


def menu_item(j, label, timeout=6):
    # A menu row's icon can carry the same label (an "xmark" image is "Close"): the row first.
    e = j.sim.wait(label=label, kind="Button", timeout=timeout) or j.sim.wait(label=label, timeout=2)
    check(e, f"no {label!r} in the menu; menu: {[x.label for x in j.sim.find(kind='Button')][:16]}")
    j.sim.tap_el(e)
    time.sleep(1.0)


def row_action(j, title, *path):
    """Hold the row, then tap each menu entry of `path` (submenus open in place).
    A hold the simulator dropped (a loaded host) is tried once more."""
    row_menu(j, title)
    if not j.sim.wait(label=path[0], timeout=4):
        row_menu(j, title)
    for label in path:
        menu_item(j, label)


def phone_order(j, titles):
    """The phone list's vertical order of `titles`."""
    ys = {}
    for t in titles:
        e = j.sim.find(prefix=t, kind="Button")
        if e:
            ys[t] = e[0].frame[1]
    return sorted(ys, key=ys.get)


# ---------------------------------------------------------------- flows

def flow_pin_color_order(j):
    names = [f"{PREFIX}a", f"{PREFIX}b", f"{PREFIX}c"]
    make_workspaces(names)
    notes = []
    # Pin
    t = time.time()
    row_action(j, names[1], "Pin Workspace")
    wait_mac(lambda: names[1] in mac_pinned_titles(), f"{names[1]} pinned")
    notes.append(f"pin on the Mac in {time.time() - t:.1f} s")
    check(j.sim.wait(label="Pinned", timeout=10), "no Pinned section on the phone")
    # Color
    t = time.time()
    row_action(j, names[1], "Appearance", "Set Workspace Color…", "Green")
    wait_mac(lambda: (mac_workspace(names[1]) or {}).get("color") == "green", f"{names[1]} green")
    notes.append(f"color green in {time.time() - t:.1f} s")
    row_action(j, names[1], "Appearance", "Reset Workspace Color")
    wait_mac(lambda: not (mac_workspace(names[1]) or {}).get("color"), f"{names[1]} color reset")
    # Unpin
    row_action(j, names[1], "Unpin Workspace")
    wait_mac(lambda: names[1] not in mac_pinned_titles(), f"{names[1]} unpinned")
    notes.append("unpinned")
    # Move: the middle one of the three up past its neighbour, in the Mac's own order
    # (new workspaces may go to the top or the bottom there).
    before = [n for n in mac_order() if n in names]
    mover = before[1]
    t = time.time()
    row_action(j, mover, "Move", "Move Workspace Up")
    want = [before[1], before[0], before[2]]
    wait_mac(lambda: [n for n in mac_order() if n in names] == want, f"order {want}")
    notes.append(f"Move Up: Mac order {before} -> {want} in {time.time() - t:.1f} s")
    time.sleep(1.5)
    check(phone_order(j, names) == want, f"phone order {phone_order(j, names)} != Mac {want}")
    row_action(j, mover, "Move", "Move Workspace Down")
    wait_mac(lambda: [n for n in mac_order() if n in names] == before, f"order back to {before}")
    notes.append("Move Down restores it")
    return "; ".join(notes)


def flow_mark_unread(j):
    name = f"{PREFIX}a"
    make_workspaces([name])
    row_action(j, name, "Options", "Mark Workspace as Unread")
    wait_mac(lambda: (mac_workspace(name) or {}).get("marked_unread") is True, f"{name} marked unread")
    row_action(j, name, "Options", "Mark Workspace as Read")
    wait_mac(lambda: not (mac_workspace(name) or {}).get("marked_unread"), f"{name} read")
    return "unread then read on the Mac"


def flow_bulk_close(j):
    names = [f"{PREFIX}x1", f"{PREFIX}x2", f"{PREFIX}x3"]
    make_workspaces(names)
    # Setup on the Mac, on this lane's own workspaces only: put them last in the person's
    # order, so Close Workspaces Below on the first closes only the other two.
    rows = (daemon({"cmd": "list-personal", "id": "p2ws"}).get("data") or {}).get("workspaces") or []
    for name in names:
        w = mac_workspace(name)
        daemon({"cmd": "set-personal-workspace", "id": "p2ws", "session_id": w["registry_id"], "workspace_key": w["key"],
                "index": len(rows) + 10})
    time.sleep(1.5)
    order = mac_order()
    first = min(names, key=order.index)
    below = order[order.index(first) + 1:]
    check(below and all(n in names for n in below),
          f"refusing: Close Workspaces Below on {first} would close {below} (not only this lane's)")
    row_action(j, first, "Close", "Close Workspaces Below")
    # The phone asks first and names what closes.
    q = j.sim.wait(contains=f"Close {len(below)} workspaces?", timeout=6)
    check(q, "no confirmation question")
    msg = " ".join(e.label or "" for e in j.sim.find(contains="close on"))
    check(all(n in msg for n in below), f"confirmation does not name {below}: {msg!r}")
    menu_item(j, "Close Workspaces")
    wait_mac(lambda: not any(mac_workspace(n) for n in below), f"{below} closed")
    check(mac_workspace(first), f"{first} closed too")
    close_on_mac([first])
    return f"closed {below} after the confirmation"


def flow_open_folder(j):
    name = f"{PREFIX}folder"
    path = proj_dir(name)
    close_on_mac([name])
    j.back_to_list()
    btn = j.sim.wait(ident="workspaces.new", timeout=10)
    check(btn, "no New Workspace button")
    x, y = btn.center
    for _ in range(2):
        j.sim.long_press(x, y, 1.2)
        time.sleep(1.2)
        if j.sim.wait(label="Open Folder…", timeout=4):
            break
    menu_item(j, "Open Folder…")
    field = j.sim.wait(ident="workspaces.openFolder.path", timeout=6) or j.sim.wait(kind="TextField", timeout=4)
    check(field, "no folder field")
    j.sim.tap_el(field)
    time.sleep(0.5)
    pq.type_text(f"~/cmux-next-ios-e2e/{name}")
    time.sleep(0.6)
    menu_item(j, "Open")
    t = time.time()
    ws = wait_mac(lambda: mac_workspace(name), f"workspace {name}")
    # Its terminal is in the folder (the typed cd).
    deadline = time.time() + 20
    cwd = None
    while time.time() < deadline:
        data = daemon({"cmd": "list-workspaces", "id": "p2ws"}).get("data") or {}
        entry = next((w for w in data.get("workspaces", []) if w.get("key") == ws["key"]), {})
        cwds = [t.get("cwd") for sc in entry.get("screens", []) for p in sc.get("panes", []) for t in p.get("tabs", [])]
        cwd = next((c for c in cwds if c), None)
        if cwd and cwd.rstrip("/") == path.rstrip("/"):
            break
        time.sleep(0.5)
    close_on_mac([name])
    check(cwd and cwd.rstrip("/") == path.rstrip("/"), f"terminal folder {cwd!r}, wanted {path}")
    return f"{name} on the Mac in {time.time() - t:.1f} s; terminal folder {cwd}"


def flow_feed_clear_all(j):
    name = f"{PREFIX}a"
    make_workspaces([name])
    mac().cmux("notify", "--title", f"{PREFIX}note", "--body", "parity round 2", check=False)
    wait_mac(lambda: mac_notifications(), "a notification")
    j.tab("Feed")
    time.sleep(1.5)
    filt = j.sim.wait(label="Filter", kind="Button", timeout=8)
    check(filt, "no Feed filter menu")
    j.sim.press(*filt.center, hold=0.1)
    time.sleep(1.2)
    menu_item(j, "Clear All Notifications")
    wait_mac(lambda: not mac_notifications(), "no notifications")
    check(not j.sim.find(label="Couldn't clear notifications"), "the phone says the clear failed")
    return "the Mac's notification list is empty"


def flow_trust_steps(j):
    """A folder Claude was never trusted in: New Agent Chat says what to do, step by step."""
    name = f"{PREFIX}trust-{time.strftime('%H%M%S')}"
    path = proj_dir(name)
    mac().cmux("workspace", "create", "--name", name, "--cwd", path, json_out=True)
    wait_mac(lambda: mac_workspace(name), f"workspace {name}")
    e = row(j, name)
    j.sim.tap_el(e)
    time.sleep(2.5)
    pq.plus_menu(j, "New Agent Chat")
    secs, toast = pq.wait_opened(j, 90)
    close_on_mac([name])
    check(toast and "isn't trusted" in toast, f"no trust steps; got {toast!r}")
    return f"in {secs:.1f} s: {toast[:160]}"


def acp(method, params):
    """One acpmux call on the rig Mac's own acpmux socket (reads and the trust answer)."""
    sock = rsh("ls -d ~/.acpmux/tags/*/acpmux.sock | grep \"$(cd %s && python3 -c 'import sys; sys.path[:0]=[\"e2e\",\".\"]; import rmac; print(rmac.mac().tag)')\" | head -1" % pq.RBASE).stdout.strip()
    check(sock, "no acpmux socket for the rig")
    r = rsh(f"python3 {pq.RBASE}/acpcall.py {shlex.quote(sock)} {shlex.quote(method)} {shlex.quote(json.dumps(params))}", timeout=60)
    out = (r.stdout or "").strip().splitlines()
    return json.loads(out[-1]) if out else {}


def flow_icon_clear_name(j):
    """Appearance › Set Icon… (hammer), Remove Icon; Options › Clear Workspace Name."""
    name, shown = f"{PREFIX}a", f"{PREFIX}a-shown"
    make_workspaces([name])
    w = mac_workspace(name)
    # Setup on the Mac (own workspace): a display name over the workspace's own name.
    daemon({"cmd": "set-workspace-metadata", "id": "p2ws", "key": w["key"], "title": shown})
    wait_mac(lambda: mac_workspace(shown), f"display name {shown}")
    row_action(j, shown, "Appearance", "Set Icon…", "hammer")
    wait_mac(lambda: (_ws_raw(w["key"]) or {}).get("icon") == "hammer", "icon hammer")
    check(j.sim.wait(ident="workspace.icon", timeout=8), "no icon on the row")
    row_action(j, shown, "Appearance", "Remove Icon")
    wait_mac(lambda: not (_ws_raw(w["key"]) or {}).get("icon"), "icon removed")
    row_action(j, shown, "Options", "Clear Workspace Name")
    wait_mac(lambda: not (_ws_raw(w["key"]) or {}).get("title"), "display name cleared")
    check(row(j, name), f"the row is not {name} again")
    return "icon hammer then removed; display name cleared, own name back"


def _ws_raw(key):
    data = daemon({"cmd": "list-workspaces", "id": "p2ws"}).get("data") or {}
    return next((w for w in data.get("workspaces", []) if w.get("key") == key), None)


def flow_agent_chat_workspace(j):
    """New Workspace (hold) › New Agent Chat › a folder: a workspace whose only tab is the chat."""
    anchor = f"{PREFIX}a"
    make_workspaces([anchor])  # its folder becomes a Recent Directory
    folder = rsh("cd ~/cmux-next-ios-e2e/p2ws-proj && pwd").stdout.strip()
    acp("acp.trust.set", {"cwd": folder, "level": "trusted"})
    before = {w["key"] for w in mac_workspaces()}
    j.back_to_list()
    btn = j.sim.wait(ident="workspaces.new", timeout=10)
    check(btn, "no New Workspace button")
    for _ in range(2):
        j.sim.long_press(*btn.center, 1.2)
        time.sleep(1.2)
        if j.sim.wait(ident="workspaces.newAgentChat.p2ws-proj", timeout=4):
            break
    e = j.sim.wait(ident="workspaces.newAgentChat.p2ws-proj", timeout=4)
    check(e, "no New Agent Chat › p2ws-proj")
    t = time.time()
    j.sim.tap_el(e)
    def created():
        for w in mac_workspaces():
            if w["key"] not in before and (w["title"] or "").startswith("p2ws-proj"):
                return _ws_raw(w["key"])
        return None
    ws = wait_mac(created, "a new chat workspace", timeout=90)
    tabs = [t for sc in ws.get("screens", []) for p in sc.get("panes", []) for t in p.get("tabs", [])]
    kinds = [t.get("kind") for t in tabs]
    close_on_mac([ws.get("title") or ws.get("name")])
    check(kinds == ["conversation"], f"tabs {kinds}, wanted only the chat")
    return f"workspace {ws.get('title') or ws.get('name')} with only the chat in {time.time() - t:.1f} s"


def flow_queue_edit(j):
    """Queued prompts: Edit queued prompt, then Send now; the agent answers the edited text."""
    # A workspace of its own: a long earlier chat would open first and fill the tree.
    anchor = f"{PREFIX}q-{time.strftime('%H%M%S')}"
    make_workspaces([anchor])
    folder = rsh("cd ~/cmux-next-ios-e2e/p2ws-proj && pwd").stdout.strip()
    acp("acp.trust.set", {"cwd": folder, "level": "trusted"})
    e = row(j, anchor)
    j.sim.tap_el(e)
    time.sleep(2.5)
    pq.plus_menu(j, "New Agent Chat")
    secs, toast = pq.wait_opened(j, 90)
    check(not toast, f"chat did not open: {toast}")
    s = j.sim
    def type_send(text):
        f = (s.wait(kind="TextView", timeout=4) or s.wait(kind="TextField", timeout=2)
             or s.wait(label="Reply to Claude", kind="Button", timeout=4))
        # While a long reply streams the accessibility tree can come back empty: the
        # composer is where it always is (above the toolbar).
        if f:
            s.tap_el(f)
        else:
            s.tap(200, 748)
        time.sleep(0.6)
        pq.type_text(text); time.sleep(0.5)
        send = s.wait(label="Send", kind="Button", timeout=5)
        if send:
            s.tap_el(send)
        else:
            s.tap(355, 748)
        time.sleep(1.5)
    type_send("Write a 1200-word short story about a lighthouse keeper, then say DONE-STORY.")
    type_send("Reply with exactly QUEUED-ALPHA")
    def queued(word):
        return next((e for e in s.find(contains=word) if e.ident == "chat.queued"
                     or any(x.ident == "chat.queued" and x.frame[1] <= e.center[1] <= x.frame[1] + x.frame[3] for x in s.find(ident="chat.queued"))), None)
    deadline = time.time() + 15
    q = None
    while time.time() < deadline and not q:
        q = queued("QUEUED-ALPHA") or (s.find(ident="chat.queued") or [None])[0]
        time.sleep(0.5)
    check(q, "no queued prompt on the phone (the first turn ended before the second was sent?)")
    s.long_press(*q.center, 1.2); time.sleep(1.2)
    menu_item(j, "Edit queued prompt")
    field = s.wait(kind="TextField", timeout=5) or s.wait(kind="TextView", timeout=3)
    check(field, "no edit field")
    s.tap_el(field); time.sleep(0.4)
    # The field holds the old text: back out "ALPHA" (HID backspace) and type the new word.
    for _ in range(len("ALPHA")):
        pq.subprocess.run(["axe", "key", "42", "--udid", load()["udid"]], capture_output=True, timeout=20)
    pq.type_text("BRAVO")
    menu_item(j, "Save")
    deadline = time.time() + 15
    q = None
    while time.time() < deadline and not q:
        q = queued("QUEUED-BRAVO")
        time.sleep(0.5)
    check(q, "the queued prompt did not change on the phone")
    s.long_press(*q.center, 1.2); time.sleep(1.2)
    menu_item(j, "Send now")
    deadline = time.time() + 180
    while time.time() < deadline:
        hits = [e for e in s.find(contains="QUEUED-BRAVO") if "Reply with" not in (e.label or "")]
        if hits:
            return "edited queued prompt sent now; the agent answered QUEUED-BRAVO"
        time.sleep(2)
    raise Fail("no QUEUED-BRAVO answer")


FLOWS = {
    "pin_color_order": flow_pin_color_order,
    "mark_unread": flow_mark_unread,
    "bulk_close": flow_bulk_close,
    "open_folder": flow_open_folder,
    "feed_clear_all": flow_feed_clear_all,
    "trust_steps": flow_trust_steps,
    "icon_clear_name": flow_icon_clear_name,
    "agent_chat_workspace": flow_agent_chat_workspace,
    "queue_edit": flow_queue_edit,
}


def run(name):
    _, _, j = ctx()
    path = rec_start(f"ws-{name}")
    t = time.time()
    try:
        notes = FLOWS[name](j)
        status = "pass"
    except Exception as e:  # noqa: BLE001
        notes = f"{type(e).__name__}: {e}"
        status = "fail"
        log(traceback.format_exc())
    finally:
        rec_stop()
    log(f"{name}: {status.upper()} ({time.time() - t:.0f} s) {notes} [{path}]")
    st = load()
    st.setdefault("ws_results", {})[name] = {"status": status, "notes": notes, "video": path}
    pq.save(st)
    return status == "pass"


def run_all():
    return {name: run(name) for name in FLOWS}


def cleanup():
    """Closes every workspace this lane made (prefix `p2ws-`), nothing else."""
    names = [w["title"] for w in mac_workspaces() if (w["title"] or "").startswith(PREFIX)]
    close_on_mac(names)
    return names
