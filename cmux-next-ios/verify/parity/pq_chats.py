"""Agent chats parity flows (feat-cmux-next-ios-chats-parity, cmux#25834 slice C): Search Agent
Chats with open in tab and in a new workspace, the Archived filter and Unarchive, Find in Chat,
Mark All Notifications as Read, and Open Chat Folder in Terminal. Same rig as pq.py and
pq_tabs.py: the phone app in ONE headless simulator, the real tagged cmux-next Mac app
(rmac.py), the real link between them. The Mac side is read on its own daemon socket
(`list-workspaces`) and acpmux socket (`_acpmux/sessions`); every action under test is done on
the phone. Chats are started from the phone with real model calls (the team subrouter).

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    PQ_HOST=local PQ_RBASE=~/cmux-next-ios-e2e/chats PQ_TAG=<rig tag> PQ_SIM=chats-phone \\
    PQ_STATE=~/cmux-next-ios-e2e/chats/state.json PQ_RAW=~/cmux-next-ios-e2e/chats/raw \\
    python3 -c 'import pq_chats as c; print(c.run("seed", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch). `seed` starts the chats
the other flows use (rig setup on the Mac: phone-started Claude chats time out at agent start
on this rig) and must run first. Workspaces it
makes are named `p2tabs-chats-*` (pq_tabs.seed's prefix).
"""
import json
import os
import re
import shlex
import time

import pq
import pq_tabs as t
from journey import Fail, check

# The rig Mac's acpmux socket: read only (`_acpmux/sessions`), to prove what the phone did.
_ACPMUX = r"""
import glob, json, os, socket, sys
paths = sorted(glob.glob(os.path.expanduser(sys.argv[1])), key=os.path.getmtime)
s = socket.socket(socket.AF_UNIX); s.connect(paths[-1]); f = s.makefile("rw")
f.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1,
        "clientInfo": {"name": "pq_chats", "version": "1"}, "clientCapabilities": {}}}) + "\n")
f.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": sys.argv[2], "params": json.loads(sys.argv[3])}) + "\n"); f.flush()
while True:
    m = json.loads(f.readline())
    if m.get("id") == 2:
        print(json.dumps(m.get("result", m))); break
"""
ACPMUX_GLOB = os.environ.get("PQ_ACPMUX_SOCK", "")


def acpmux(method, params=None):
    check(ACPMUX_GLOB, "PQ_ACPMUX_SOCK (the rig Mac's acpmux socket glob) is not set")
    r = pq.rsh(f"python3 -c {shlex.quote(_ACPMUX)} {shlex.quote(ACPMUX_GLOB)} {shlex.quote(method)} "
               f"{shlex.quote(json.dumps(params or {}))}", timeout=60)
    check(r.returncode == 0, f"acpmux {method}: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def mac_session(session_id):
    for s in acpmux("_acpmux/sessions").get("sessions", []):
        if s.get("sessionId") == session_id:
            return s
    return None


def archived_on_mac(session_id):
    s = mac_session(session_id) or {}
    return "archived" in (s.get("tags") or {})


def same_folder(a, b):
    """The same folder on the rig Mac, whichever side resolved symlinks (/tmp, /private/tmp)."""
    if not a or not b:
        return False
    norm = lambda p: os.path.realpath(p) if pq.HOST == "local" else p
    return norm(a.rstrip("/")) == norm(b.rstrip("/"))


def state():
    return pq.load().setdefault("chats", {})


def save_state(**kw):
    st = pq.load()
    st.setdefault("chats", {}).update(kw)
    pq.save(st)


def chat_cards(j):
    """The seed workspace's chat card (its only tab that is not the `p2tabs-t1` terminal)."""
    return [e for e in j.sim.find(suffix=", tab") if not (e.label or "").startswith("p2tabs-t")]


def open_ws(j, name):
    """pq_tabs.open_ws from wherever the last flow left the phone: an open menu is closed, a
    workspace's tab grid left by its back chevron, and the Workspaces tab chosen."""
    if j.sim.find(label="Mark All Notifications as Read", kind="Button") or j.sim.find(label="Clear All Notifications", kind="Button"):
        j.sim.tap(60, 820)
        time.sleep(1.0)
    if j.sim.find(label="1 Tab") or j.sim.find(contains=" Tabs"):
        j.sim.tap(37, 85)
        time.sleep(1.5)
    if j.sim.find(label="Workspaces", kind="RadioButton"):
        j.tab("Workspaces")
        time.sleep(1.0)
    t.open_ws(j, name)


def ocr_text(j):
    return " | ".join(o[4] for o in j.sim.ocr())


def menu_items(j):
    return [e.label for e in j.sim.find(kind="Button") if e.label]


def open_page_menu(j):
    bottom = [e for e in j.sim.find(kind="Button") if e.frame[1] > 740 and e.frame[2] > 120]
    check(bottom, "no title capsule at the bottom")
    j.sim.tap_el(bottom[0])
    time.sleep(1.2)
    return menu_items(j)


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


def close_menu(j):
    j.sim.tap(200, 300)
    time.sleep(0.8)


def chat_session(key):
    """The (surface, session) of the conversation tabs of workspace `key` on the Mac."""
    return t.conversations(key)


# ---------------------------------------------------------------- flows

def start_chat(folder, prompt):
    """A chat on the Mac, started and prompted over its local acpmux socket (rig setup: the
    Mac's own chats, which the phone's list shows). Returns its session id once it answered."""
    made = acpmux("session/new", {"cwd": folder, "mcpServers": [], "_meta": {"acpmux": {"harness": "claude", "policy": "ask"}}})
    sid = made["sessionId"]
    r = pq.rsh(f"python3 -c {shlex.quote(_ACPMUX)} {shlex.quote(ACPMUX_GLOB)} session/prompt "
               f"{shlex.quote(json.dumps({'sessionId': sid, 'prompt': [{'type': 'text', 'text': prompt}]}))}", timeout=300)
    check(r.returncode == 0, f"prompt: {r.stderr.strip()[:300]}")
    return sid


def seed(j, label):
    """Rig setup on the Mac (not the phone): a `p2tabs-chats-seed-*` workspace with one terminal,
    and two chats in its folder with real model replies: PONG (then archived, as the Mac's chat
    menu Archive does) and kiwi (five lines of the word, for Find in Chat). The kiwi chat is
    shown as a tab of the seed workspace."""
    a = t.seed("chats-seed", terminals=1)
    # The folder's trust is the person's answer on the Mac (a phone may not give it).
    folder = pq.rsh(f"cd {t.PROJ} && pwd -P").stdout.strip()
    acpmux("acp.trust.set", {"cwd": folder, "level": "trusted"})
    pong = start_chat(folder, "Reply with the single word PONG.")
    kiwi = start_chat(folder, "Write the word kiwi on five separate lines, nothing else.")
    acpmux("_acpmux/archive", {"sessionId": pong, "archived": True})
    pane = t.ws_tabs(t.mac_workspace(key=a["key"]))[0][0]
    host = pq.rsh("ps eww -o command -p $(pgrep -f 'chats-parity.app/Contents/Resources/bin/cmux-mobile-host') "
                  "| tr ' ' '\\n' | sed -n 's/^CMUX_MOBILE_AGENT_TAB_HOST=//p'").stdout.strip()
    check(host, "the rig Mac's agent tab host")
    t.mac_raw({"cmd": "new-conversation-tab", "pane": pane, "agent_session": {"host": host, "harness": "claude", "session": kiwi}})
    save_state(seed_ws=a["name"], seed_key=a["key"], pong=pong, kiwi=kiwi, host=host)
    titles = {s["sessionId"]: s.get("title") for s in acpmux("_acpmux/sessions").get("sessions", [])}
    return {"pong": pong, "kiwi": kiwi, "titles": {pong: titles.get(pong), kiwi: titles.get(kiwi)},
            "pong_archived": archived_on_mac(pong)}


def chats_list(j, label):
    """A fresh workspace's terminal: page menu > Search Agent Chats, a search, a tap (the chat
    as a tab here), then Open in New Workspace from a row's menu. Before: no such item."""
    st = state()
    b = t.seed("chats-list", terminals=1)
    open_ws(j, b["name"])
    items = open_page_menu(j)
    pq.shot(f"chats-{label}-page-menu")
    row = j.sim.find(label="Search Agent Chats", kind="Button")
    if label == "before":
        close_menu(j)
        check(not row, "the base app has Search Agent Chats")
        return {"page_menu": items, "search_agent_chats": False}
    row = [menu_row(j, "Search Agent Chats")]
    pq.shot(f"chats-{label}-page-menu-scrolled")
    check(row[0], f"no Search Agent Chats: {items}")
    j.sim.tap_el(row[0])
    list_shown = j.sim.wait(ident="agentChats.list", timeout=30)
    check(list_shown, "the chats list never loaded")
    time.sleep(1.5)
    pq.shot(f"chats-{label}-list")
    rows = [e.label for e in j.sim.find(prefix="agentChats.row.")] or [e.label for e in j.sim.find(kind="Button") if "·" in (e.label or "")]
    field = j.sim.wait(kind="SearchField", timeout=5) or j.sim.wait(kind="TextField", timeout=3)
    check(field, "no search field")
    j.sim.tap_el(field)
    time.sleep(0.6)
    pq.type_text("kiwi")
    time.sleep(1.5)
    pq.shot(f"chats-{label}-search")
    hit = j.sim.wait(ident=f"agentChats.row.{st['pong']}", timeout=2)
    check(not hit, "the archived PONG chat shows in a kiwi search")
    hit = j.sim.wait(ident=f"agentChats.row.{st['kiwi']}", timeout=8)
    check(hit, f"the kiwi chat is not in the search results: {ocr_text(j)[:300]}")
    tabs_before = len(t.ws_tabs(t.mac_workspace(key=b["key"])))
    tapped = time.time()
    j.sim.tap_el(hit)
    opened, took = t.until(lambda: [s for _, s in chat_session(b["key"]) if s == st["kiwi"]], timeout=45,
                           what="the chat's tab in this workspace on the Mac")
    time.sleep(3)
    pq.shot(f"chats-{label}-opened-here")
    # Open in New Workspace: the row's menu (long press).
    open_page_menu(j)
    j.sim.tap_el(menu_row(j, "Search Agent Chats"))
    j.sim.wait(ident="agentChats.list", timeout=30)
    time.sleep(1.0)
    row = j.sim.wait(ident=f"agentChats.row.{st['kiwi']}", timeout=8)
    check(row, "no kiwi row the second time")
    before_ws = {w.get("key") for w in t.mac_tree().get("workspaces", [])}
    x, y = row.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(1.0)
    pq.shot(f"chats-{label}-row-menu")
    item = j.sim.wait(label="Open in New Workspace", kind="Button", timeout=5)
    check(item, f"no Open in New Workspace: {menu_items(j)}")
    j.sim.tap_el(item)

    def new_ws():
        for w in t.mac_tree().get("workspaces", []):
            if w.get("key") not in before_ws and any(
                    ((tab.get("conversation") or {}).get("agent_session") or {}).get("session") == st["kiwi"]
                    for _, tab in t.ws_tabs(w)):
                return w
        return None

    ws, took_ws = t.until(new_ws, timeout=45, what="the new workspace with the chat on the Mac")
    time.sleep(3)
    pq.shot(f"chats-{label}-new-workspace")
    return {"rows": rows[:8], "opened_here_s": round(took, 1), "tabs_before": tabs_before,
            "tabs_after": len(t.ws_tabs(t.mac_workspace(key=b["key"]))),
            "new_workspace": ws.get("name") or ws.get("title"), "new_workspace_s": round(took_ws, 1),
            "new_workspace_tabs": [tab.get("kind") for _, tab in t.ws_tabs(ws)]}


def archived(j, label):
    """Chats list > Filter > Archived shows the archived PONG chat; Unarchive (swipe) removes
    the Mac's archived tag. Before: no list to filter."""
    st = state()
    check(archived_on_mac(st["pong"]), "the PONG chat is not archived on the Mac (run seed)")
    open_ws(j, st["seed_ws"])
    items = open_page_menu(j)
    row = j.sim.find(label="Search Agent Chats", kind="Button")
    if label == "before":
        pq.shot(f"archived-{label}-page-menu")
        close_menu(j)
        return {"page_menu": items, "archived_list": False, "mac_archived": archived_on_mac(st["pong"])}
    j.sim.tap_el(menu_row(j, "Search Agent Chats"))
    j.sim.wait(ident="agentChats.list", timeout=30)
    time.sleep(1.0)
    hidden = not j.sim.find(ident=f"agentChats.row.{st['pong']}")
    f = j.sim.wait(ident="agentChats.filter", timeout=5) or j.sim.wait(label="Filter", kind="Button", timeout=3)
    check(f, "no Filter")
    j.sim.tap_el(f)
    time.sleep(1.0)
    check(hidden, "the archived chat shows in the Chats list (the Mac's lists hide it)")
    pq.shot(f"archived-{label}-filter-menu")
    a = j.sim.wait(label="Archived", timeout=5)
    check(a, f"no Archived in the filter: {menu_items(j)}")
    j.sim.tap_el(a)
    time.sleep(1.5)
    pq.shot(f"archived-{label}-archived-list")
    row = j.sim.wait(ident=f"agentChats.row.{st['pong']}", timeout=8)
    check(row, f"the archived chat is not listed: {ocr_text(j)[:300]}")
    x, y = row.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(1.0)
    item = j.sim.wait(label="Unarchive", kind="Button", timeout=5)
    check(item, f"no Unarchive: {menu_items(j)}")
    pq.shot(f"archived-{label}-row-menu")
    j.sim.tap_el(item)
    _, took = t.until(lambda: not archived_on_mac(st["pong"]), timeout=30, what="Unarchive on the Mac")
    time.sleep(1.5)
    pq.shot(f"archived-{label}-unarchived")
    return {"hidden_in_chats": hidden, "unarchived_s": round(took, 1), "mac_archived_after": archived_on_mac(st["pong"])}


def find(j, label):
    """The kiwi chat: page menu > Find in Chat…, "kiwi": N of M, then Previous and Next. Before:
    no Find in Chat."""
    st = state()
    open_ws(j, st["seed_ws"])
    pq.open_grid(j)
    cards = chat_cards(j)
    check(cards, f"no chat card: {[e.label for e in j.sim.find(suffix=', tab')]}")
    j.sim.tap_el(cards[0])
    time.sleep(2.0)
    items = open_page_menu(j)
    pq.shot(f"find-{label}-page-menu")
    row = j.sim.find(label="Find in Chat…", kind="Button")
    if label == "before":
        close_menu(j)
        check(not row, "the base app has Find in Chat")
        return {"page_menu": items, "find": False}
    row = [menu_row(j, "Find in Chat…")]
    check(row[0], f"no Find in Chat…: {items}")
    j.sim.tap_el(row[0])
    time.sleep(1.0)
    pq.type_text("kiwi")
    time.sleep(2.0)
    pq.shot(f"find-{label}-first")

    def count():
        e = [x for x in j.sim.find(kind="StaticText") if re.match(r"^\d+ of \d+$", x.label or "") or (x.label or "") == "No results"]
        return e[0].label if e else ""

    counts = [count()]
    for name in ("Previous match", "Previous match", "Next match"):
        b = j.sim.wait(label=name, kind="Button", timeout=4)
        check(b, f"no {name} button")
        j.sim.tap_el(b)
        time.sleep(1.2)
        counts.append(count())
        pq.shot(f"find-{label}-step{len(counts) - 1}")
    done = j.sim.wait(label="Done", kind="Button", timeout=4)
    if done:
        j.sim.tap_el(done)
        time.sleep(1.0)
    pq.shot(f"find-{label}-done")
    parsed = [re.match(r"(\d+) of (\d+)$", c or "") for c in counts]
    check(all(parsed), f"the bar did not count matches: {counts}")
    total = int(parsed[0].group(2))
    at = [int(m.group(1)) for m in parsed]
    check(total >= 5 and at[0] == total, f"want the newest of at least 5 first: {counts}")
    check(at[1] == total - 1 and at[2] == total - 2 and at[3] == total - 1, f"Previous, Previous, Next did not step: {counts}")
    return {"counts": counts}


def mark_all_read(j, label):
    """Two terminals post a notification (OSC 777, typed into the Mac terminal by the rig), then
    the Feed's Filter menu > Mark All Notifications as Read: the Mac's tabs read. Before: no item."""
    c = t.seed("chats-notify", terminals=2)
    surfaces = [tab["surface"] for _, tab in t.ws_tabs(c)]
    for n, surface in enumerate(surfaces, start=1):
        t.mac_raw({"cmd": "send", "surface": surface,
                   "text": f"printf '\\033]777;notify;cmux parity;build {n} finished\\007'\r"})

    def unread():
        markers = {tab["surface"]: (tab.get("notification") or {}).get("unread") for _, tab in t.ws_tabs(t.mac_workspace(key=c["key"]))}
        return [s for s in surfaces if markers.get(s)]

    shown, _ = t.until(lambda: unread() if len(unread()) == len(surfaces) else None, timeout=30, what="unread notifications on the Mac")
    if j.sim.find(label="1 Tab") or j.sim.find(contains=" Tabs"):
        j.sim.tap(37, 85)
        time.sleep(1.5)
    j.back_to_list()
    j.tab("Feed")
    time.sleep(2.0)
    f = j.sim.wait(label="Filter", kind="Button", timeout=8)
    check(f, "no Feed Filter")
    j.sim.tap_el(f)
    time.sleep(1.0)
    items = menu_items(j)
    pq.shot(f"markread-{label}-menu")
    row = j.sim.find(label="Mark All Notifications as Read", kind="Button")
    if label == "before":
        close_menu(j)
        check(not row, "the base app has Mark All Notifications as Read")
        return {"menu": items, "mark_all": False, "mac_unread": unread()}
    check(row, f"no Mark All Notifications as Read: {items}")
    j.sim.tap_el(row[0])
    _, took = t.until(lambda: not unread(), timeout=30, what="the Mac's tabs to read")
    time.sleep(1.5)
    pq.shot(f"markread-{label}-after")
    return {"mac_unread_before": shown, "mac_unread_after": unread(), "read_s": round(took, 1)}


def folder_terminal(j, label):
    """The kiwi chat: page menu > Open Chat Folder in Terminal: a new terminal tab beside the
    chat on the Mac, in the chat's folder. Before: no item."""
    st = state()
    open_ws(j, st["seed_ws"])
    pq.open_grid(j)
    cards = chat_cards(j)
    check(cards, "no chat card")
    j.sim.tap_el(cards[0])
    time.sleep(2.0)
    items = open_page_menu(j)
    pq.shot(f"folder-{label}-page-menu")
    row = j.sim.find(label="Open Chat Folder in Terminal", kind="Button")
    if label == "before":
        close_menu(j)
        check(not row, "the base app has Open Chat Folder in Terminal")
        return {"page_menu": items, "folder_terminal": False}
    row = [menu_row(j, "Open Chat Folder in Terminal")]
    check(row[0], f"no Open Chat Folder in Terminal: {items}")
    folder = (mac_session(st["kiwi"]) or {}).get("cwd")
    every = lambda: [(ws, p, tab) for ws in t.mac_tree().get("workspaces", []) for p, tab in t.ws_tabs(ws)]
    before = {tab["surface"] for _, _, tab in every()}
    # The panes that show the kiwi chat (the phone's open tab is one of them).
    chat_panes = {p for _, p, tab in every() if ((tab.get("conversation") or {}).get("agent_session") or {}).get("session") == st["kiwi"]}
    j.sim.tap_el(row[0])

    def new_terminal():
        for ws, pane, tab in every():
            if tab["surface"] not in before and tab.get("kind") == "pty":
                return pane, tab
        return None

    (pane, tab), took = t.until(new_terminal, timeout=30, what="a new terminal on the Mac")
    # The typed cd lands a moment after the tab: the Mac's own cwd report follows the shell.
    cwd, _ = t.until(lambda: next((x.get("cwd") for _, _, x in every() if x["surface"] == tab["surface"] and same_folder(x.get("cwd"), folder)), None),
                     timeout=20, what="the new terminal to reach the chat's folder")
    tab["cwd"] = cwd
    time.sleep(3)
    pq.shot(f"folder-{label}-terminal")
    return {"chat_folder": folder, "terminal_cwd": tab.get("cwd"), "same_pane_as_chat": pane in chat_panes, "took_s": round(took, 1)}


FLOWS = {"seed": seed, "chats": chats_list, "archived": archived, "find": find, "markread": mark_all_read,
         "folder": folder_terminal}


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
