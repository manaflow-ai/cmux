"""Parity round 2, tabs lane: tab moves, pins, tab groups, agent chat Fork / Archive /
Duplicate, drag to reorder, and the browser's Forward and address (verify/parity-mac.md).

Each flow does the action on the phone (the app in ONE headless simulator), proves the Mac
changed (the rig Mac's own daemon tree through its bundled CLI, read only) and records a
video. Flows touch only workspaces they create, named `p2tabs-*`.

    PQ_SIM=cmux-mobile-p2-tabs PQ_STATE=~/cmux-next-ios-e2e/p2tabs-state.json PQ_RAW=~/cmux-next-ios-e2e/p2tabs-raw \\
    PQ_RBASE=~/cmux-next-ios-e2e/p2 python3 -c 'import pq_tabs as t; t.run("pin")'
    python3 -c 'import pq_tabs as t; t.run_all()'

`setup()` of pq.py (sign-in, the rig Mac) comes first, once.
"""
import json
import os
import subprocess
import time

import pq
from journey import Fail, check

# The rig Mac's layout for this round (PQ_RBASE; pq.py's default is the first parity round's).
if "PQ_RBASE" not in os.environ:
    pq.RBASE = "~/cmux-next-ios-e2e/p2"
HERE = os.path.dirname(os.path.abspath(__file__))
CNX = os.path.normpath(os.path.join(HERE, "../.."))
PROJ = f"{pq.RBASE}/proj"


# ---------------------------------------------------------------- the Mac side (read only, plus seeding)

# The rig Mac's daemon socket (its tag): read and seeded directly, since the bundled CLI
# speaks the public resource API and shows no daemon ids. Read only, except for seeding.
TAG = os.environ.get("PQ_TAG", "cmux-mobile-p2-1585ab34")
_DAEMON = r"""
import glob, json, os, socket, sys
# The app's daemon socket: under the per-user temp folder, or /tmp/cmux-tui-<uid> (newer builds).
paths = [p for d in (os.environ.get("TMPDIR", "/tmp"), "/tmp")
         for p in glob.glob(os.path.join(d, "cmux-tui-%d" % os.getuid(), "cmux-app-%s.sock" % sys.argv[1]))]
s = socket.socket(socket.AF_UNIX); s.connect(paths[0]); f = s.makefile("rw")
# Chat tabs read as `conversation` (with their agent session) only for a client that says it knows them.
f.write(json.dumps({"id": 0, "cmd": "set-client-info", "name": "pq_tabs", "kind": "cli",
                    "capabilities": ["conversation-tabs-v1", "agent-session-tabs-v1"]}) + "\n")
f.write(sys.argv[2] + "\n"); f.flush()
while True:
    line = f.readline()
    if json.loads(line).get("id") == 1:
        print(line); break
"""


def mac_raw(request):
    """One daemon command on the rig Mac's own daemon socket."""
    import shlex
    line = json.dumps(dict(request, id=1))
    r = pq.rsh(f"python3 -c {shlex.quote(_DAEMON)} {shlex.quote(TAG)} {shlex.quote(line)}", timeout=60)
    check(r.returncode == 0, f"daemon {request.get('cmd')}: {r.stderr.strip()[:300]}")
    reply = json.loads(r.stdout)
    check(reply.get("ok", True), f"daemon {request.get('cmd')}: {reply.get('error')}")
    return reply.get("data", reply)


def mac_tree():
    return mac_raw({"cmd": "list-workspaces"})


def mac_workspace(name=None, key=None):
    for ws in mac_tree().get("workspaces", []):
        if (key and ws.get("key") == key) or (name and (ws.get("name") == name or ws.get("title") == name)):
            return ws
    return None


def ws_tabs(ws):
    """[(pane id, tab)] of a workspace, in pane order."""
    out = []
    for screen in (ws or {}).get("screens", []):
        for pane in screen.get("panes", []):
            for tab in pane.get("tabs", []):
                out.append((pane.get("id"), tab))
    return out


def where(surface):
    """The workspace holding `surface` on the Mac, or None."""
    for ws in mac_tree().get("workspaces", []):
        if any(t.get("surface") == surface for _, t in ws_tabs(ws)):
            return ws
    return None


def seed(tag, terminals=2):
    """A `p2tabs-<tag>-HHMMSS` workspace in the rig's project folder with `terminals` terminals,
    each renamed `p2tabs-t<n>` so the phone's cards are easy to find."""
    name = f"p2tabs-{tag}-{time.strftime('%H%M%S')}"
    proj = pq.rsh(f"mkdir -p {PROJ} && cd {PROJ} && pwd").stdout.strip()
    pq.RemoteMac().cmux("workspace", "create", "--name", name, "--cwd", proj, json_out=True)
    ws = mac_workspace(name=name)
    check(ws, f"seed workspace {name} not on the Mac")
    pane = ws_tabs(ws)[0][0]
    for _ in range(terminals - 1):
        mac_raw({"cmd": "new-tab", "pane": pane})
    ws = mac_workspace(name=name)
    for n, (_, tab) in enumerate(ws_tabs(ws), start=1):
        mac_raw({"cmd": "rename-surface", "surface": tab["surface"], "name": f"p2tabs-t{n}"})
    return mac_workspace(name=name)


# ---------------------------------------------------------------- the phone side

def open_ws(j, name):
    j.back_to_list()
    row = j.sim.wait(prefix=name, kind="Button", timeout=45)
    check(row, f"{name} not on the phone")
    j.sim.tap_el(row)
    time.sleep(2.5)


def card(j, title, timeout=15):
    """A grid card ("<title>, tab")."""
    e = j.sim.wait(prefix=f"{title}, tab", kind="Button", timeout=timeout)
    check(e, f"no card {title!r}; cards: {[x.label for x in j.sim.find(suffix=', tab')]}")
    return e


def card_menu(j, title, item):
    """Long press on a card (its menu), then the row `item`."""
    e = card(j, title)
    x, y = e.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(0.8)
    row = j.sim.wait(label=item, kind="Button", timeout=6)
    check(row, f"no {item!r} in {title}'s card menu: {[x.label for x in j.sim.find(kind='Button')][:20]}")
    j.sim.tap_el(row)
    time.sleep(1.0)


def open_tab(j, title):
    """The grid, then the card `title` (its page)."""
    pq.open_grid(j)
    j.sim.tap_el(card(j, title))
    time.sleep(1.5)


def page_menu(j, item):
    """The page menu (a tap on the bottom title capsule), then the row `item`."""
    bottom = [e for e in j.sim.find(kind="Button") if e.frame[1] > 740 and e.frame[2] > 120]
    check(bottom, "no title capsule at the bottom")
    j.sim.tap_el(bottom[0])
    time.sleep(1.0)
    row = j.sim.wait(label=item, kind="Button", timeout=6)
    check(row, f"no {item!r} in the page menu: {[x.label for x in j.sim.find(kind='Button')][:24]}")
    j.sim.tap_el(row)
    time.sleep(1.0)


def scroll_to(j, tries=8, **query):
    """An element of a lazy list (a sheet's rows load as they scroll in): swipes up until it shows."""
    for _ in range(tries):
        e = j.sim.wait(timeout=2, **query)
        if e and e.frame[1] + e.frame[3] < 840:
            return e
        j.sim.swipe(200, 760, 200, 520, 0.3)
        time.sleep(0.8)
    return None


def until(fn, timeout=20, what="the Mac to change"):
    t = time.time()
    last = None
    while time.time() - t < timeout:
        last = fn()
        if last:
            return last, time.time() - t
        time.sleep(0.5)
    raise Fail(f"timed out waiting for {what}")


def flow(name):
    """Records the flow to PQ_RAW/<name>.mp4; returns its result line."""
    def wrap(fn):
        def run(*args, **kwargs):
            sim, mac, j = pq.ctx()
            pq.rec_start(name)
            try:
                return fn(j, *args, **kwargs)
            finally:
                pq.rec_stop()
        run.__name__ = name
        FLOWS[name] = run
        return run
    return wrap


FLOWS = {}


# ---------------------------------------------------------------- flows

@flow("move-to-workspace")
def move_to_workspace(j):
    """Page menu > Move Tab to Workspace… > another workspace: the Mac moves the tab there."""
    a, b = seed("move-a"), seed("move-b", terminals=1)
    surface = ws_tabs(a)[1][1]["surface"]
    open_ws(j, a["name"])
    open_tab(j, "p2tabs-t2")
    page_menu(j, "Move Tab to Workspace…")
    dest = scroll_to(j, ident=f"move-to.{b['key']}")
    check(dest, f"{b['name']} not in the picker: {[e.ident for e in j.sim.find(ident='move-to.*')]}")
    j.sim.tap_el(dest)
    landed, secs = until(lambda: (where(surface) or {}).get("key") == b["key"], what="the tab in the other workspace")
    pq.open_grid(j)
    check(not j.sim.find(prefix="p2tabs-t2, tab"), "the card stayed on the phone")
    return f"Mac: surface {surface} in {b['name']} after {secs:.1f} s"


@flow("move-to-new-workspace")
def move_to_new_workspace(j):
    """Page menu > Move Tab to New Workspace: a new Mac workspace holds the tab, named after it."""
    a = seed("movenew")
    surface = ws_tabs(a)[1][1]["surface"]
    open_ws(j, a["name"])
    open_tab(j, "p2tabs-t2")
    page_menu(j, "Move Tab to New Workspace")
    ws, secs = until(lambda: (lambda w: w if w and w.get("key") != a["key"] else None)(where(surface)),
                     what="a new workspace")
    return f"Mac: surface {surface} in new workspace {ws.get('name')!r} after {secs:.1f} s"


@flow("pin")
def pin(j):
    """Card menu > Pin Tab, then Unpin Tab: the Mac's `pinned` flag follows."""
    a = seed("pin")
    surface = ws_tabs(a)[1][1]["surface"]
    pinned = lambda: next((t.get("pinned") for _, t in ws_tabs(mac_workspace(key=a["key"])) if t["surface"] == surface), None)
    open_ws(j, a["name"])
    pq.open_grid(j)
    card_menu(j, "p2tabs-t2", "Pin Tab")
    _, s1 = until(lambda: pinned() is True, what="the pin")
    # Pinned tabs sort first on the Mac (and so on the phone).
    first = ws_tabs(mac_workspace(key=a["key"]))[0][1]["surface"]
    card_menu(j, "p2tabs-t2", "Unpin Tab")
    _, s2 = until(lambda: pinned() is False, what="the unpin")
    return f"Mac: pinned in {s1:.1f} s (first in its pane: {first == surface}), unpinned in {s2:.1f} s"


@flow("tab-groups")
def tab_groups(j):
    """New Tab Group on one tab, then Add Tab to Group… on another: both in one Mac group."""
    a = seed("groups", terminals=3)
    s1, s2 = ws_tabs(a)[0][1]["surface"], ws_tabs(a)[1][1]["surface"]
    group_of = lambda s: next((t.get("group") for _, t in ws_tabs(mac_workspace(key=a["key"])) if t["surface"] == s), None)

    open_ws(j, a["name"])
    pq.open_grid(j)
    card_menu(j, "p2tabs-t1", "New Tab Group")
    gid, t1 = until(lambda: group_of(s1), what="the new group")
    card_menu(j, "p2tabs-t2", "Add Tab to Group…")
    pick = j.sim.wait(kind="Button", contains="group", timeout=8)
    check(pick, "no group in the picker")
    j.sim.tap_el(pick)
    _, t2 = until(lambda: group_of(s2) == gid, what="the second member")
    pq.shot("p2tabs-groups")  # the members' cards carry the group's chip
    return f"Mac: group {gid}: created in {t1:.1f} s, second member in {t2:.1f} s"


def _group_actions(j, title, item):
    """A member card's "Tab Group: <name>…" row, then `item` in the group's actions."""
    e = card(j, title)
    x, y = e.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(0.8)
    row = [b for b in j.sim.find(kind="Button") if (b.label or "").startswith("Tab Group: ")]
    check(row, "no Tab Group row")
    j.sim.tap_el(row[0])
    time.sleep(1.0)
    act = j.sim.wait(label=item, kind="Button", timeout=6)
    check(act, f"no {item!r} in the group's actions")
    j.sim.tap_el(act)
    time.sleep(1.0)


@flow("tab-groups-2")
def tab_groups_2(j):
    """Rename Tab Group…, Pin Group, Ungroup Tabs on a group made on the phone."""
    a = seed("groups2", terminals=2)
    s1 = ws_tabs(a)[0][1]["surface"]

    def group_run():
        for scr in mac_workspace(key=a["key"]).get("screens", []):
            for p in scr.get("panes", []):
                for g in p.get("tab_groups", []) or []:
                    if s1 in g.get("surfaces", []):
                        return g
        return None

    open_ws(j, a["name"])
    pq.open_grid(j)
    card_menu(j, "p2tabs-t1", "New Tab Group")
    until(group_run, what="the new group")
    _group_actions(j, "p2tabs-t1", "Rename Tab Group…")
    pq.type_text("p2tabs-review")
    ok = j.sim.wait(label="Rename", kind="Button", timeout=5)
    check(ok, "no Rename in the alert")
    j.sim.tap_el(ok)
    _, r = until(lambda: (group_run() or {}).get("name", "").lower() == "p2tabs-review", what="the group name")
    _group_actions(j, "p2tabs-t1", "Pin Group")
    _, p = until(lambda: (group_run() or {}).get("saved_id"), what="the saved group")
    _group_actions(j, "p2tabs-t1", "Ungroup Tabs")
    _, u = until(lambda: group_run() is None, what="the ungroup")
    return f"Mac: renamed in {r:.1f} s, pinned (saved) in {p:.1f} s, ungrouped in {u:.1f} s"


@flow("reorder")
def reorder(j):
    """Drag to reorder with real touches (CmuxMobileAppUITests on this simulator) against the Mac."""
    a = seed("reorder", terminals=3)
    before = [t["surface"] for _, t in ws_tabs(a)]
    st = pq.load()
    pq.rec_stop()  # xcodebuild launches the app itself; the recording restarts below
    pq.rec_start("reorder")
    # TEST_RUNNER_* reach the test process from xcodebuild's environment (not as build settings).
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
               TEST_RUNNER_CMUX_MOBILE_UI_WORKSPACE=a["key"], TEST_RUNNER_CMUX_MOBILE_UI_SLOTS="3")
    r = subprocess.run([
        "xcodebuild", "-project", f"{CNX}/CmuxMobileApp.xcodeproj", "-scheme", "CmuxMobileApp", "-configuration", "Debug",
        "-destination", f"id={st['udid']}", "-derivedDataPath", f"{CNX}/build/dd", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
        "-only-testing:CmuxMobileAppUITests/TabReorderUITests", "test-without-building"],
        capture_output=True, text=True, timeout=540, env=env)
    # The test ends with the app closed, and the simulator's accessibility tree (which the
    # other flows read through axe) stays empty until it restarts: restart it, open the app.
    for args in (["shutdown"], ["boot"], ["bootstatus", "-b"], ["launch"]):
        tail = [pq.BUNDLE] if args == ["launch"] else []
        subprocess.run(["xcrun", "simctl", *args, st["udid"], *tail], capture_output=True, env=env, timeout=300)
    time.sleep(5)
    lines = [ln for ln in r.stdout.splitlines() if "CMUX_MOBILE_UI_" in ln or "error:" in ln or "TEST " in ln]
    check(r.returncode == 0, "XCUITest failed: " + " | ".join(lines)[-600:])
    after, secs = until(lambda: (lambda o: o if o != before else None)([t["surface"] for _, t in ws_tabs(mac_workspace(key=a["key"]))]),
                        what="the Mac's order")
    check(after == before[1:3] + before[:1] + before[3:], f"Mac order {after}, wanted {before[1:3] + before[:1]}")
    return f"Mac pane order {before} -> {after} ({' | '.join(lines)})"


def _agent_tab(j, name):
    """A phone-started agent chat in workspace `name` that has answered once."""
    pq.plus_menu(j, "New Agent Chat")
    secs, bad = pq.wait_opened(j, timeout=90)
    check(not bad, f"New Agent Chat refused: {bad}")
    pq.chat_prompt(j, "Reply with the single word PONG.", "PONG", timeout=240)
    return secs


def conversations(key):
    return [(t["surface"], ((t.get("conversation") or {}).get("agent_session") or {}).get("session"))
            for _, t in ws_tabs(mac_workspace(key=key)) if t.get("kind") == "conversation"]


@flow("chat-fork-duplicate-archive")
def chat_fork_duplicate_archive(j):
    """Page menu > Fork (a new chat, its own session), Duplicate Tab (a second tab of the same
    chat), Archive (the tab closes on the Mac)."""
    a = seed("chat", terminals=1)
    open_ws(j, a["name"])
    _agent_tab(j, a["name"])
    first = conversations(a["key"])
    check(len(first) == 1, f"one chat expected, Mac has {first}")
    page_menu(j, "Fork")
    forks, f = until(lambda: (lambda c: c if len(c) == 2 else None)(conversations(a["key"])), timeout=90, what="the fork")
    check(forks[1][1] and forks[1][1] != first[0][1], f"fork has its own session: {forks}")
    page_menu(j, "Duplicate Tab")
    dup, d = until(lambda: (lambda c: c if len(c) == 3 else None)(conversations(a["key"])), what="the duplicate")
    sessions = [s for _, s in dup]
    page_menu(j, "Archive")
    left, r = until(lambda: (lambda c: c if len(c) == 2 else None)(conversations(a["key"])), what="the archive")
    return (f"Mac: fork {forks[1][1][:8]} in {f:.1f} s; duplicate shares a session ({len(set(sessions))} sessions "
            f"for 3 tabs) in {d:.1f} s; archive closed a tab in {r:.1f} s")


@flow("browser-forward")
def browser_forward(j):
    """Back, then Forward once at once: the Mac's page is forward again with one tap. The address
    reads the page's host (VoiceOver: "Address, <host>"), never about:blank."""
    a = seed("browser", terminals=1)
    open_ws(j, a["name"])
    pq.plus_menu(j, "New Browser Tab")
    pq.wait_opened(j, timeout=60)

    def go(host):
        addr = j.sim.wait(prefix="Address", kind="Button", timeout=10)
        check(addr, "no address field")
        j.sim.tap_el(addr)
        time.sleep(0.8)
        pq.type_text(f"https://{host}\n")
        time.sleep(4)

    def page_url():
        """The page the Mac's browser host shows, as it reports it (`rb.page` drives the address).
        The daemon's tab record keeps about:blank for a streamed tab, so it can't say."""
        e = j.sim.find(prefix="Address", kind="Button")
        return (e[0].label or "") if e else ""

    go("example.com")
    go("www.iana.org")
    until(lambda: "iana.org" in page_url(), timeout=30, what="iana.org from the Mac's browser")
    label = page_url()
    check("about:blank" not in label, f"address reads {label!r}")
    def tap(label):
        e = j.sim.wait(label=label, kind="Button", timeout=3)
        check(e, f"no {label} button")
        j.sim.tap_el(e)

    # Back reaches the Mac's page.
    tap("Back")
    until(lambda: "example.com" in page_url(), timeout=15, what="Back on the Mac")
    tap("Forward")
    until(lambda: "iana.org" in page_url(), timeout=15, what="Forward on the Mac")
    # Finding 5: Back, then Forward at once; one tap must land (it used to need a second).
    tap("Back")
    t0 = time.time()
    tap("Forward")
    gap = time.time() - t0
    seen = []
    while time.time() - t0 < 8:
        u = page_url()
        if not seen or seen[-1] != u:
            seen.append(u)
        time.sleep(0.3)
    check("iana.org" in seen[-1], f"one Forward right after Back did not land: {seen}")
    s = gap
    mac_record = next((t.get("url") or "" for _, t in ws_tabs(mac_workspace(key=a["key"])) if t.get("kind") == "browser"), "")
    return (f"address {label!r}; Back then one Forward: the Mac's page at {page_url()!r} {s:.1f} s after Back (addresses after it {seen}) "
            f"(the daemon's tab record says {mac_record!r})")


ORDER = ["pin", "move-to-workspace", "move-to-new-workspace", "tab-groups", "tab-groups-2", "reorder",
         "browser-forward", "chat-fork-duplicate-archive"]


def run(name):
    t = time.time()
    try:
        line = FLOWS[name]()
        pq.log(f"PASS {name}: {line} ({time.time() - t:.0f} s)")
        return True, line
    except Exception as e:  # a failed flow says why and the next one runs
        pq.log(f"FAIL {name}: {e}")
        return False, str(e)


def run_all(names=None):
    return {n: run(n) for n in (names or ORDER)}


def cleanup():
    """Closes every `p2tabs-*` workspace this lane created on the rig Mac."""
    for ws in mac_tree().get("workspaces", []):
        if (ws.get("name") or "").startswith("p2tabs-"):
            mac_raw({"cmd": "close-workspace", "key": ws["key"]})
