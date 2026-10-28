"""Parity round 3, orchestrator flows: the round-2 items that were only unit-tested, driven
live (the Mac's last pick, queued prompts, a Mac-started Codex chat in Agent mode), then the
round-3 lanes. Same rig as pq.py (env PQ_SIM, PQ_STATE, PQ_RAW, PQ_RBASE, PQ_HOST).

Mac-side picks go through the rig Mac's own New Tab page (its real UI), driven in the
background with cua-driver on the rig mini (`cuax.py`, accessibility actions only).
"""
import json
import shlex
import time

import pq
from journey import Fail, check


def acp(method, params, timeout=60):
    """One acpmux call on the rig Mac's own socket (the Mac side, never the phone's lane)."""
    tag = pq.rsh(f"cd {pq.RBASE} && python3 -c 'import sys; sys.path[:0]=[\"e2e\",\".\"]; import rmac; print(rmac.mac().tag)'").stdout.strip()
    sock = f"~/.acpmux/tags/{tag}/acpmux.sock"
    r = pq.rsh(f"python3 {pq.RBASE}/acpcall.py {sock} {shlex.quote(method)} {shlex.quote(json.dumps(params))}", timeout=timeout)
    out = (r.stdout or "").strip().splitlines()
    return json.loads(out[-1]) if out else {"error": r.stderr[-300:]}


def sessions():
    """The rig Mac's acpmux sessions (`_acpmux/sessions`)."""
    r = acp("_acpmux/sessions", {})
    res = r.get("result") or {}
    return res.get("sessions", res if isinstance(res, list) else [])


def proj():
    return pq.rsh(f"cd {pq.RBASE}/proj && pwd").stdout.strip()


def trust(folder):
    return acp("acp.trust.set", {"cwd": folder, "level": "trusted"})


def last_picks():
    return (acp("_acpmux/harnesses", {}).get("result") or {}).get("lastPicks")


def flow_last_pick(expect_model="claude-haiku-5-5"):
    """The Mac's New Tab page picked Haiku (its real UI); the phone's New Agent Chat in a
    workspace folder the Mac never picked in starts on the Mac's global pick."""
    picks = last_picks()
    check(picks and (picks.get("global") or {}).get("model") == expect_model, f"Mac pick not in acpmux: {picks}")
    folder = proj()
    trust(folder)
    before = {s.get("sessionId") or s.get("id") for s in sessions()}
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    pq.rec_start("last-pick")
    try:
        pq.plus_menu(j, "New Agent Chat")
        opened, toast = pq.wait_opened(j, 120)
        check(not toast, f"start refused: {toast}")
        took, text = pq.chat_prompt(j, "Reply with exactly the word PONG and nothing else.", "PONG", timeout=180)
        pq.shot("last-pick")
    finally:
        pq.rec_stop()
    new = [x for x in sessions() if (x.get("sessionId") or x.get("id")) not in before]
    check(new, "no new acpmux session on the Mac")
    sess = new[-1]
    return {"picks": picks, "session": {k: sess.get(k) for k in ("harness", "model", "modelId", "cwd", "policy", "mode", "currentModeId")},
            "opened_s": round(opened, 1), "reply_s": round(took, 1)}


def session(sid):
    return next((x for x in sessions() if x.get("sessionId") == sid), None)


def face_id(match=True):
    udid = pq.load()["udid"]
    sp = ["xcrun", "simctl", "spawn", udid, "notifyutil"]
    pq.subprocess.run(sp + ["-s", "com.apple.BiometricKit.enrollmentChanged", "1"], capture_output=True)
    pq.subprocess.run(sp + ["-p", "com.apple.BiometricKit.enrollmentChanged"], capture_output=True)
    if match is not None:
        time.sleep(1.5)
        pq.subprocess.run(sp + ["-p", "com.apple.BiometricKit_Sim.pearl." + ("match" if match else "nomatch")], capture_output=True)


def type_send(j, text):
    """The chat composer (also while a turn runs), then Send."""
    s = j.sim
    f = (s.wait(kind="TextView", timeout=4) or s.wait(kind="TextField", timeout=2)
         or s.wait(contains="Reply to", kind="Button", timeout=8))
    # While a reply streams the accessibility tree can come back empty: the composer is
    # where it always is (above the toolbar).
    # Never a blind tap: the permission bar takes the composer's place (its Deny is there).
    check(f, "no composer (a permission bar in its place?)")
    s.tap_el(f)
    time.sleep(0.8)
    pq.type_text(text)
    time.sleep(0.6)
    send = s.wait(label="Send", kind="Button", timeout=5)
    check(send, "no Send button after typing")
    s.tap_el(send)
    time.sleep(1.5)


def queued_row(j, word):
    """A queued prompt's row: its text beside a "Remove queued message" button (the
    workspace page's identifier covers the row's own `chat.queued`)."""
    s = j.sim
    els = s.find()
    xs = [e for e in els if e.label == "Remove queued message"]
    for e in els:
        if word in (e.label or "") and e.kind == "StaticText" and \
                any(abs(x.center[1] - e.center[1]) < 16 for x in xs):
            return e
    return None


def wait_for(fn, what, timeout=30, every=0.5):
    t = time.time()
    while time.time() - t < timeout:
        v = fn()
        if v:
            return v, time.time() - t
        time.sleep(every)
    raise Fail(f"timed out waiting for {what}")


def hold_menu(j, el, item):
    import pq_ws
    j.sim.long_press(*el.center, 1.2)
    time.sleep(1.2)
    pq_ws.menu_item(j, item)


def flow_queue():
    """A long turn (an approved 90 s perl wait; this mini's Claude hooks block `sleep`), two prompts sent meanwhile queue on the Mac;
    Move up, Edit queued prompt and Send now from the phone, each read back on the Mac."""
    folder = proj()
    trust(folder)
    before = {x.get("sessionId") for x in sessions()}
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    out = {}
    pq.rec_start("queue")
    try:
        pq.plus_menu(j, "New Agent Chat")
        opened, toast = pq.wait_opened(j, 120)
        check(not toast, f"start refused: {toast}")
        face_id(match=None)
        type_send(j, "Use your Bash tool in the foreground to run ./wait90.sh then reply DONE-WAIT")
        sid = wait_for(lambda: next((x["sessionId"] for x in sessions() if x.get("sessionId") not in before), None),
                       "the new session on the Mac", 30)[0]
        # Allow each permission the agent asks for (Face ID), until the command runs.
        t0 = time.time()
        while time.time() - t0 < 120:
            x = session(sid) or {}
            if x.get("pendingPermissions"):
                allow = s.find(label="Allow once", kind="Button") or s.find(label="Allow Once", kind="Button")
                if allow:
                    pq.shot("queue-permission")
                    s.tap_el(allow[0])
                    time.sleep(1.5)
                    face_id(True)
                    time.sleep(2)
                    continue
            elif x.get("turn") and s.find(label="Running, ./wait90.sh") and s.find(contains="Reply to", kind="Button"):
                break
            time.sleep(1)
        check((session(sid) or {}).get("turn"), "the turn ended before the second prompt (the command did not wait)")
        check(not (session(sid) or {}).get("pendingPermissions"), "a permission still waits")
        type_send(j, "Reply with exactly QUEUED-ALPHA")
        type_send(j, "Reply with exactly QUEUED-CHARLIE")
        q, _ = wait_for(lambda: (lambda x: x and len(x.get("queue") or []) == 2 and x["queue"])(session(sid)),
                        "two prompts queued on the Mac", 20)
        out["queued_on_mac"] = [json.dumps(e)[:160] for e in q]
        wait_for(lambda: queued_row(j, "QUEUED-CHARLIE"), "the queued rows on the phone", 15)
        pq.shot("queue-two")
        hold_menu(j, queued_row(j, "QUEUED-CHARLIE"), "Move up")
        q, took = wait_for(lambda: (lambda x: x and "CHARLIE" in json.dumps((x.get("queue") or [{}])[0]) and x["queue"])(session(sid)),
                           "CHARLIE first on the Mac", 15)
        out["move_up_s"] = round(took, 1)
        hold_menu(j, queued_row(j, "QUEUED-ALPHA"), "Edit queued prompt")
        field = s.wait(kind="TextField", timeout=5) or s.wait(kind="TextView", timeout=3)
        check(field, "no edit field")
        # The caret at the end of the old text (a tap in the middle puts it there).
        fx, fy, fw, fh = field.frame
        s.tap(fx + fw - 6, fy + fh / 2)
        time.sleep(0.5)
        pq.subprocess.run(["axe", "key", "77", "--udid", pq.load()["udid"]], capture_output=True, timeout=20)
        for _ in range(len("ALPHA")):
            pq.subprocess.run(["axe", "key", "42", "--udid", pq.load()["udid"]], capture_output=True, timeout=20)
        pq.type_text("BRAVO")
        time.sleep(0.5)
        import pq_ws
        pq_ws.menu_item(j, "Save")
        q, took = wait_for(lambda: (lambda x: x and "QUEUED-BRAVO" in json.dumps(x.get("queue") or []) and x["queue"])(session(sid)),
                           "the edited prompt on the Mac", 15)
        out["edit_s"] = round(took, 1)
        out["queue_after_edit"] = [json.dumps(e)[:160] for e in q]
        wait_for(lambda: queued_row(j, "QUEUED-BRAVO"), "BRAVO on the phone", 10)
        pq.shot("queue-edited")
        hold_menu(j, queued_row(j, "QUEUED-BRAVO"), "Send now")
        q, took = wait_for(lambda: (lambda x: x is not None and "QUEUED-BRAVO" not in json.dumps(x.get("queue") or []) and (x.get("queue") or [None]))(session(sid)),
                           "BRAVO to leave the Mac's queue", 20)
        out["send_now_s"] = round(took, 1)
        out["queue_after_send_now"] = [json.dumps(e)[:160] for e in (q if isinstance(q, list) else [])]
        wait_for(lambda: [e for e in s.find(contains="QUEUED-BRAVO") if "Reply with" not in (e.label or "")
                          and e.ident != "chat.queued"], "the BRAVO answer", 200, 2)
        wait_for(lambda: [e for e in s.find(contains="QUEUED-CHARLIE") if "Reply with" not in (e.label or "")
                          and e.ident != "chat.queued"], "the CHARLIE answer", 200, 2)
        pq.shot("queue-done")
        out["session"] = sid
        return out
    finally:
        pq.rec_stop()


def _tabs():
    import pq_tabs as t
    t.TAG = pq.rsh(f"cd {pq.RBASE} && python3 -c 'import sys; sys.path[:0]=[\"e2e\",\".\"]; import rmac; print(rmac.mac().tag)'").stdout.strip()
    return t


def proc_line(pid):
    return pq.rsh(f"ps -o pid=,ppid=,command= -p {pid}; ps -o pid=,command= -p $(ps -o ppid= -p {pid}) | cut -c1-200; "
                  f"lsof -a -p {pid} -d cwd -Fn | grep ^n").stdout.strip()


def flow_saved_group():
    """Reopen Saved Tab Group, live (SECURITY.md "Reopen Saved Tab Group"): a saved group of two
    terminals whose shells ended; the phone reopens it; the Mac starts NEW login shells under
    the rig app's own terminal host, in the saved folders; then Delete Saved Tab Group…"""
    t = _tabs()
    ws = t.seed("saved", terminals=3)
    name = ws.get("name") or ws.get("title")
    tabs = t.ws_tabs(ws)
    pane, s1, s2, s3 = tabs[0][0], tabs[0][1]["surface"], tabs[1][1]["surface"], tabs[2][1]["surface"]
    pq.rsh("mkdir -p /tmp/p3saved-check")
    t.mac_raw({"cmd": "send", "surface": s3, "text": "cd /tmp/p3saved-check\r"})
    time.sleep(2)
    g = t.mac_raw({"cmd": "create-tab-group", "surfaces": [s2, s3], "color": "red"})
    gid = next(x["id"] for x in t.mac_raw({"cmd": "list-tab-groups"})["groups"] if s2 in x.get("surfaces", []))
    t.mac_raw({"cmd": "update-tab-group", "group": gid, "name": "P3SAVED"})
    sv = t.mac_raw({"cmd": "save-tab-group", "group": gid})
    saved = next((x.get("saved_id") for x in t.mac_raw({"cmd": "list-tab-groups"})["groups"] if x["id"] == gid), None) or json.dumps(sv)[:200]
    before = {s: (t.mac_raw({"cmd": "process-info", "surface": s}) or {}).get("pid") for s in (s2, s3)}
    t.mac_raw({"cmd": "close-tab-group", "group": gid, "end_terminals": True})
    listed = t.mac_raw({"cmd": "list-saved-tab-groups"})
    out = {"group": gid, "saved": saved, "old_pids": before, "saved_record": json.dumps(listed)[:600]}
    s, m, j = pq.ctx()
    pq.rec_start("reopen-saved-group")
    try:
        t.open_ws(j, name)
        t.open_tab(j, "p2tabs-t1")
        t.page_menu(j, "Reopen Saved Tab Group…")
        row = s.wait(contains="P3SAVED", timeout=15)
        check(row, f"no P3SAVED in the chooser: {[e.label for e in s.find(kind='Button')][:12]}")
        pq.shot("saved-chooser")
        s.tap_el(row)
        ws2, took = t.until(lambda: (lambda w: w if len(t.ws_tabs(w)) >= 3 else None)(t.mac_workspace(name=name)),
                            timeout=40, what="the reopened tabs on the Mac")
        out["reopen_s"] = round(took, 1)
        new = [tab["surface"] for _, tab in t.ws_tabs(ws2) if tab["surface"] != s1]
        procs = {}
        for sfc in new:
            pid = None
            for _ in range(20):
                pid = (t.mac_raw({"cmd": "process-info", "surface": sfc}) or {}).get("pid")
                if pid:
                    break
                time.sleep(1)
            procs[sfc] = {"pid": pid, "ps": proc_line(pid) if pid else ""}
        out["new"] = procs
        check(all(p["pid"] and p["pid"] not in before.values() for p in procs.values()), f"not new shells: {procs}")
        time.sleep(2)
        pq.shot("saved-reopened")
        # Delete Saved Tab Group…: the record goes, the open group stays.
        t.page_menu(j, "Delete Saved Tab Group…")
        row = s.wait(contains="P3SAVED", timeout=15)
        check(row, "no P3SAVED in the delete chooser")
        s.tap_el(row)
        time.sleep(1.5)
        confirm = s.wait(label="Delete", kind="Button", timeout=4) or s.wait(contains="Delete Saved", kind="Button", timeout=2)
        if confirm:
            s.tap_el(confirm)
        _, took = t.until(lambda: "P3SAVED" not in json.dumps(t.mac_raw({"cmd": "list-saved-tab-groups"})),
                          timeout=20, what="the saved record to go")
        out["delete_s"] = round(took, 1)
        out["open_after_delete"] = len(t.ws_tabs(t.mac_workspace(name=name)))
        pq.shot("saved-deleted")
        return out
    finally:
        pq.rec_stop()


def personal():
    import pq_ws
    return pq_ws.daemon({"cmd": "list-personal", "id": "p3"}).get("data") or {}


def group_named(name):
    return next((g for g in personal().get("groups", []) if g.get("name") == name), None)


def ws_group(key):
    return next((w.get("group") for w in personal().get("workspaces", []) if w.get("workspace_key") == key), "missing")


def alert_type(j, text, button):
    """An alert's text field (cleared), `text`, then its `button`."""
    import pq_ws
    s = j.sim
    f = s.wait(kind="TextField", timeout=6)
    check(f, "no text field in the alert")
    s.tap_el(f)
    time.sleep(0.4)
    for _ in range(len(f.value or "") + 2):
        pq.subprocess.run(["axe", "key", "42", "--udid", pq.load()["udid"]], capture_output=True, timeout=20)
    pq.type_text(text)
    time.sleep(0.4)
    pq_ws.menu_item(j, button)


def header(j, name):
    return j.sim.wait(contains=name, ident="workspace.group.*", timeout=10) or j.sim.wait(prefix=name, timeout=4)


def flow_groups():
    """Workspace groups from the phone, each read back from the Mac's personal order."""
    import pq_ws
    a, b = "p3g-a", "p3g-b"
    pq_ws.PREFIX = "p3g-"
    pq_ws.make_workspaces([a, b])
    ka, kb = pq_ws.mac_workspace(a)["key"], pq_ws.mac_workspace(b)["key"]
    s, m, j = pq.ctx()
    out = {}
    pq.rec_start("groups")
    try:
        # 1. Move Workspace to New Group "Ship".
        pq_ws.row_action(j, a, "Group", "Move Workspace to Group…", "Move Workspace to New Group")
        alert_type(j, "Ship", "Create")
        g = pq_ws.wait_mac(lambda: group_named("Ship"), "the Ship group")
        pq_ws.wait_mac(lambda: ws_group(ka) == g["id"], "a in Ship")
        out["create"] = {k: g.get(k) for k in ("id", "name", "color", "collapsed")}
        pq.shot("groups-created")
        # 2. Rename Group… "Release", then Set Workspace Group Color… > Cyan.
        h = header(j, "Ship")
        check(h, "no Ship header on the phone")
        j.sim.long_press(*h.center, 1.2); time.sleep(1.2)
        pq_ws.menu_item(j, "Rename Group…")
        alert_type(j, "Release", "Rename")
        pq_ws.wait_mac(lambda: group_named("Release"), "the rename")
        h = header(j, "Release")
        j.sim.long_press(*h.center, 1.2); time.sleep(1.2)
        pq_ws.menu_item(j, "Set Workspace Group Color…")
        pq_ws.menu_item(j, "Cyan")
        out["color"] = pq_ws.wait_mac(lambda: (lambda x: x and x.get("color") == "cyan" and x["color"])(group_named("Release")), "cyan")
        # 3. Tap the header: collapsed on the Mac; tap again: expanded.
        j.sim.tap_el(header(j, "Release"))
        pq_ws.wait_mac(lambda: (group_named("Release") or {}).get("collapsed") is True, "collapsed")
        pq.shot("groups-collapsed")
        j.sim.tap_el(header(j, "Release"))
        pq_ws.wait_mac(lambda: (group_named("Release") or {}).get("collapsed") is False, "expanded")
        out["collapse"] = "collapsed then expanded"
        # 4. b into Release, then Remove Workspace from Group.
        pq_ws.row_action(j, b, "Group", "Move Workspace to Group…")
        # The group's header in the list reads "Release" too: the menu's row is the last.
        choice = [e for e in j.sim.find(label="Release", kind="Button")]
        check(choice, "no Release in Move Workspace to Group…")
        j.sim.tap_el(choice[-1])
        pq_ws.wait_mac(lambda: ws_group(kb) == g["id"], "b in Release")
        pq_ws.row_action(j, b, "Group", "Remove Workspace from Group")
        pq_ws.wait_mac(lambda: ws_group(kb) in (None, ""), "b out of the group")
        out["place"] = "b in, then out"
        # 5. Delete Group (asks first): the group goes, a stays open.
        h = header(j, "Release")
        j.sim.long_press(*h.center, 1.2); time.sleep(1.2)
        pq_ws.menu_item(j, "Delete Group")
        pq_ws.menu_item(j, "Delete Group")
        pq_ws.wait_mac(lambda: not group_named("Release"), "the group deleted")
        check(pq_ws.mac_workspace(a), "a closed with its group")
        out["delete"] = "group gone, a still open"
        pq.shot("groups-deleted")
        return out
    finally:
        pq.rec_stop()
        pq_ws.close_on_mac([a, b])


def flow_duplicate():
    """Duplicate Workspace from the phone: the Mac lists a second workspace of the same name with
    the same terminals in the same folders (each a new login shell of the Mac's own host)."""
    import pq_ws
    t = _tabs()
    name = f"p3d-{time.strftime('%H%M%S')}"
    pq.rsh("mkdir -p /tmp/p3dup")
    proj = pq.rsh(f"cd {pq.RBASE}/proj && pwd").stdout.strip()
    pq.RemoteMac().cmux("workspace", "create", "--name", name, "--cwd", proj, json_out=True)
    src = t.mac_workspace(name=name)
    pane = t.ws_tabs(src)[0][0]
    t.mac_raw({"cmd": "new-tab", "pane": pane})
    s2 = t.ws_tabs(t.mac_workspace(name=name))[1][1]["surface"]
    t.mac_raw({"cmd": "send", "surface": s2, "text": "cd /tmp/p3dup\r"})
    time.sleep(3)
    s, m, j = pq.ctx()
    pq.rec_start("duplicate-workspace")
    try:
        pq_ws.row_action(j, name, "Duplicate Workspace")
        def copies():
            ws = [w for w in t.mac_tree().get("workspaces", []) if (w.get("name") or w.get("title")) == name]
            return ws if len(ws) == 2 and len(t.ws_tabs(ws[-1])) >= 2 else None
        both, took = t.until(copies, timeout=40, what="the copy on the Mac")
        time.sleep(3)
        copy = next(w for w in both if w.get("key") != src.get("key"))
        cwds = []
        for _, tab in t.ws_tabs(copy):
            pid = (t.mac_raw({"cmd": "process-info", "surface": tab["surface"]}) or {}).get("pid")
            cwds.append(proc_line(pid) if pid else None)
        pq.shot("duplicate")
        return {"copy_s": round(took, 1), "tabs": len(t.ws_tabs(copy)), "shells": cwds}
    finally:
        pq.rec_stop()


def flow_cmux_agent():
    """The `cmux` harness on a team the model router refuses: the phone must end the turn with
    a clear message (not sit on "Working")."""
    import pq_main
    trust(proj())
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    before = {x.get("sessionId") for x in sessions()}
    pq.rec_start("cmux-agent-403")
    try:
        opened, toast = pq_main.start_with(j, "Claude Code (cmux)")
        check(not toast, f"start refused: {toast}")
        t0 = time.time()
        type_send(j, "Reply with exactly the word PONG and nothing else.")
        hit, took = wait_for(lambda: s.find(contains="Agent stopped") or s.find(contains="model service")
                             or [e for e in s.find(contains="PONG") if "Reply with" not in (e.label or "")], "the turn to end", 300, 2)
        pq.shot("cmux-agent-403")
        texts = [e.label for e in s.find() if e.label and ("model service" in e.label or "Agent stopped" in e.label
                                                         or "403" in e.label or "isn't" in e.label)]
        new = [x for x in sessions() if x.get("sessionId") not in before]
        last = (new[-1] if new else {}).get("lastTurn")
        return {"opened_s": round(opened, 1), "ended_s": round(took, 1), "phone": texts[:6], "mac_last_turn": json.dumps(last)[:400]}
    finally:
        pq.rec_stop()


def allow_pending(j, sid, timeout=120, done=None):
    """Allow once (Face ID) each permission the session asks for, until `done()` or idle."""
    s = j.sim
    t0 = time.time()
    labels = []
    while time.time() - t0 < timeout:
        x = session(sid) or {}
        if x.get("pendingPermissions"):
            btns = [e.label for e in s.find(kind="Button")]
            allow = s.find(label="Allow once", kind="Button")
            if allow:
                labels.append([b for b in btns if b in ("Allow once", "Deny", "Allow for this session", "Always", "Allow for This Chat", "Reply instead")])
                s.tap_el(allow[0])
                time.sleep(1.5)
                face_id(True)
                time.sleep(2)
                continue
        elif not x.get("turn") and (done is None or done()):
            return labels
        time.sleep(1)
    raise Fail("the turn did not finish")


def flow_edits_artifacts():
    """Agent Edits (a file written, then edited twice across turns) and Files and Artifacts
    (an SVG preview), against the same session on the Mac. Also records the permission bar's
    choices (only Allow once and Deny from a phone)."""
    import pq_tabs as t
    folder = proj()
    trust(folder)
    pq.rsh(f"cd {folder} && rm -f p3-notes.txt p3.svg")
    before = {x.get("sessionId") for x in sessions()}
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    out = {}
    pq.rec_start("edits-artifacts")
    try:
        pq.plus_menu(j, "New Agent Chat")
        opened, toast = pq.wait_opened(j, 120)
        check(not toast, f"start refused: {toast}")
        face_id(match=None)
        type_send(j, "Use your Write tool to create p3-notes.txt with exactly three lines: one, two, three. Then reply DONE-1")
        sid = wait_for(lambda: next((x["sessionId"] for x in sessions() if x.get("sessionId") not in before), None), "session", 30)[0]
        out["bar"] = allow_pending(j, sid)
        type_send(j, "Use your Edit tool to change the line two to TWO in p3-notes.txt. Then reply DONE-2")
        time.sleep(3)
        allow_pending(j, sid)
        type_send(j, "Use your Edit tool to change the line three to THREE in p3-notes.txt. Then reply DONE-3")
        time.sleep(3)
        allow_pending(j, sid)
        type_send(j, "Use your Write tool to create p3.svg containing an SVG of a red circle, 100 by 100. Then reply DONE-4")
        time.sleep(3)
        allow_pending(j, sid)
        out["mac_file"] = pq.rsh(f"cat {folder}/p3-notes.txt; ls -la {folder}/p3.svg").stdout.strip()
        t.page_menu(j, "Agent Edits")
        time.sleep(2.5)
        pq.shot("agent-edits")
        out["edits_screen"] = [e.label for e in s.find() if e.label][:40]
        b = s.find(label="Done", kind="Button") or s.find(label="Close", kind="Button")
        if b:
            s.tap_el(b[0]); time.sleep(1.2)
        t.page_menu(j, "Files and Artifacts")
        time.sleep(2)
        svg = s.wait(contains="p3.svg", timeout=10)
        check(svg, f"no p3.svg in Files and Artifacts: {[e.label for e in s.find() if e.label][:30]}")
        s.tap_el(svg)
        time.sleep(3)
        pq.shot("artifact-svg")
        out["svg_screen"] = [e.label for e in s.find() if e.label][:30]
        out["session"] = sid
        return out
    finally:
        pq.rec_stop()


def pending_permission(sid):
    r = acp("_acpmux/events", {"sessionId": sid, "after": 0, "limit": 1000})
    ids = []
    for e in (r.get("result") or {}).get("events", []):
        if e.get("kind") == "permission_request":
            ids.append(e["msg"].get("permissionId"))
        if e.get("kind") == "permission_decision":
            ids = [i for i in ids if i != e["msg"].get("permissionId")]
    return ids[-1] if ids else None


def flow_feed_permission():
    """A permission in the Feed: only Allow once and Deny; answered on the Mac first, the
    phone's tap closes the card as answered there (not an error)."""
    folder = proj()
    trust(folder)
    before = {x.get("sessionId") for x in sessions()}
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    out = {}
    pq.rec_start("feed-permission")
    try:
        pq.plus_menu(j, "New Agent Chat")
        opened, toast = pq.wait_opened(j, 120)
        check(not toast, f"start refused: {toast}")
        type_send(j, "Use your Bash tool to run: echo p3feed > p3feed.txt. Then reply DONE-FEED")
        sid = wait_for(lambda: next((x["sessionId"] for x in sessions() if x.get("sessionId") not in before), None), "session", 30)[0]
        wait_for(lambda: (session(sid) or {}).get("pendingPermissions"), "the permission", 90)
        j.back_to_list()
        j.tab("Feed")
        time.sleep(3)
        pq.shot("feed-permission")
        card = s.wait(ident="feed.permission.pending", timeout=20)
        btns = [e.label for e in s.find(kind="Button")]
        out["feed_buttons"] = [b for b in btns if b and any(w in b for w in ("Allow", "Deny", "Always", "session"))]
        pid = pending_permission(sid)
        # acpmux accepts an Allow only from the cmux app's person connection (never a script);
        # a Deny from the Mac's own socket answers it there all the same.
        out["mac_answer"] = json.dumps(acp("_acpmux/permission_respond", {"sessionId": sid, "permissionId": pid, "optionId": "reject_once"}))[:200]
        wait_for(lambda: not (session(sid) or {}).get("pendingPermissions"), "the Mac's answer", 20)
        allow = s.find(label="Allow once", kind="Button")
        check(allow, f"no Allow once in the Feed (card {bool(card)}): {btns[:20]}")
        s.tap_el(allow[0])
        time.sleep(1.5)
        face_id(True)
        hit, took = wait_for(lambda: s.find(contains="Already answered"), "Already answered on your Mac", 20)
        out["phone_after"] = hit[0].label
        out["errors"] = [e.label for e in s.find() if e.label and ("rror" in e.label or "no pending" in e.label)]
        pq.shot("feed-answered-elsewhere")
        out["file"] = pq.rsh(f"cat {folder}/p3feed.txt").stdout.strip()
        return out
    finally:
        pq.rec_stop()


def flow_answered_on_mac_in_chat():
    """A permission open in the phone's chat is answered on the Mac (a Deny from its socket):
    the chat's bar must close on its own; a late tap must not error."""
    folder = proj()
    trust(folder)
    before = {x.get("sessionId") for x in sessions()}
    s, m, j = pq.ctx()
    pq.open_workspace(j)
    out = {}
    pq.rec_start("answered-on-mac-chat")
    try:
        pq.plus_menu(j, "New Agent Chat")
        opened, toast = pq.wait_opened(j, 120)
        check(not toast, f"start refused: {toast}")
        type_send(j, "Use your Bash tool to run: echo p3mac > p3mac.txt. Then reply DONE-MAC")
        sid = wait_for(lambda: next((x["sessionId"] for x in sessions() if x.get("sessionId") not in before), None), "session", 30)[0]
        wait_for(lambda: (session(sid) or {}).get("pendingPermissions"), "the permission", 90)
        wait_for(lambda: s.find(label="Allow once", kind="Button"), "the bar on the phone", 20)
        pq.shot("mac-answer-before")
        pid = pending_permission(sid)
        acp("_acpmux/permission_respond", {"sessionId": sid, "permissionId": pid, "optionId": "reject_once"})
        t0 = time.time()
        gone = None
        while time.time() - t0 < 20:
            if not s.find(label="Allow once", kind="Button"):
                gone = round(time.time() - t0, 1)
                break
            time.sleep(0.5)
        out["bar_closed_after_s"] = gone
        pq.shot("mac-answer-after")
        if gone is None:
            s.tap_el(s.find(label="Allow once", kind="Button")[0])
            time.sleep(1.5)
            face_id(True)
            time.sleep(3)
            out["after_late_tap"] = [e.label for e in s.find() if e.label and ("nswered" in e.label or "rror" in e.label or "pending" in e.label)]
            pq.shot("mac-answer-late-tap")
        return out
    finally:
        pq.rec_stop()


def flow_chief():
    """Home > Chief: the conversation loads, a message gets the Mac Chief's reply; Chief
    settings show the Mac's engine."""
    s, m, j = pq.ctx()
    out = {}
    pq.rec_start("chief")
    try:
        j.back_to_list()
        j.tab("Home")
        s.tap_q(ident="home.chief")
        _, took = wait_for(lambda: not s.find(ident="conversation.initialLoading") and s.find(ident="conversation.transcript"),
                           "the Chief conversation", 30)
        out["loaded_s"] = round(took, 1)
        field = s.wait(ident="conversation.composer.text", timeout=5)
        check(field, f"no Chief composer: {[e.label for e in s.find(kind='Button')][:15]}")
        s.tap_el(field)
        time.sleep(0.6)
        pq.type_text("Reply with exactly CHIEFPONG and nothing else")
        time.sleep(0.5)
        send = s.wait(ident="conversation.composer.send", timeout=4) or s.wait(label="Send", kind="Button", timeout=2) \
            or s.wait(contains="Send", kind="Button", timeout=2)
        check(send, f"no Send: {[e.label for e in s.find(kind='Button')][:20]}")
        s.tap_el(send)
        hit, took = wait_for(lambda: [e for e in s.find(contains="CHIEFPONG") if "Reply with" not in (e.label or "")],
                             "the Chief's reply", 180, 2)
        out["reply_s"] = round(took, 1)
        pq.shot("chief-reply")
        st = s.find(ident="chief.settings")
        if st:
            s.tap_el(st[0]); time.sleep(2)
            pq.shot("chief-settings")
            out["settings"] = [e.label for e in s.find() if e.label and e.ident and e.ident.startswith("chief.settings")][:12]
            # Chief's info is pushed (Back); older builds showed a sheet (Done).
            d = s.find(ident="chief.settings.done") or [e for e in s.find(label="Back", kind="Button") if e.frame[1] < 130]
            if d:
                s.tap_el(d[0]); time.sleep(1)
        eng = m.cmux("chief", "engine", check=False, timeout=30)
        out["mac_engine"] = (eng.stdout or eng.stderr).strip()[:300]
        return out
    finally:
        pq.rec_stop()


def flow_codex_agent_mode(sid):
    """A Codex chat the Mac started (its default Agent mode, which doesn't ask): a phone's
    prompt to it (Feed > Reply) is refused by cmux-mobile-host, and the session gets no new turn."""
    s, m, j = pq.ctx()
    out = {}
    turns_before = (session(sid) or {}).get("turnCount")
    pq.rec_start("codex-agent-mode")
    try:
        j.back_to_list()
        j.tab("Feed")
        time.sleep(3)
        card = wait_for(lambda: [e for e in s.find(contains="MACPONG")], "the Mac's Codex reply in the Feed", 30)[0][0]
        pq.shot("codex-feed")
        replies = [e for e in s.find(label="Reply") if e.center[1] > card.center[1]]
        check(replies, "no Reply under the Codex card")
        s.tap_el(sorted(replies, key=lambda e: e.center[1])[0])
        time.sleep(1.5)
        f = s.wait(kind="TextView", timeout=5) or s.wait(kind="TextField", timeout=3) or s.wait(kind="TextArea", timeout=3)
        check(f, f"no reply field: {[e.label for e in s.find(kind='Button')][:15]}")
        s.tap_el(f)
        time.sleep(0.5)
        pq.type_text("Reply with exactly PHONEPONG")
        time.sleep(0.5)
        send = s.wait(label="Send reply", kind="Button", timeout=5) or s.wait(label="Send", kind="Button", timeout=2)
        check(send, f"no Send: {[e.label for e in s.find(kind='Button')][:15]}")
        s.tap_el(send)
        hit, took = wait_for(lambda: s.find(contains="mode that doesn't ask") or s.find(contains="doesn’t ask")
                             or s.find(contains="PHONEPONG", kind="StaticText"), "the refusal", 60)
        pq.shot("codex-refused")
        out["phone"] = [e.label for e in hit][:3]
        time.sleep(5)
        x = session(sid) or {}
        out["mac"] = {"mode": x.get("currentModeId"), "turns_before": turns_before, "turns_after": x.get("turnCount"),
                      "lastPrompt": x.get("lastPrompt")}
        return out
    finally:
        pq.rec_stop()
