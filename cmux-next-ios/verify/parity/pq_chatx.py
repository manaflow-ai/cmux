"""Chat polish parity flows (feat-cmux-next-ios-chat-polish-parity, cmux#25834): the copy rows,
Session Info, Jump to Turn with bookmarks and pins, Text and Width, Read Aloud, the permission
rows, the Event Inspector, Replay Conversation, Launch Claude/Codex Teams and Message Chief.

Same rig as pq_crows.py: the phone app in ONE headless simulator, the real tagged cmux-next Mac
app (rmac.py), the real link between them. Every action under test is done on the phone; after
each one the Mac's state is read back from the rig app's acpmux socket (`_acpmux/info`,
`_acpmux/bookmark_get`, `_acpmux/permission_groups`, `_acpmux/events`), its daemon socket
(`list-workspaces`, `read-screen`) or its Chief conversation.

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    . ~/cmux-next-ios-e2e/chatx/env.sh && python3 -c 'import pq_chatx as c; print(c.run("copy", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import re
import shlex
import subprocess
import time

import pq
import pq_crows as c
import pq_rows as r
import pq_tabs as t
from journey import Fail, check


def udid():
    return pq.load()["udid"]


def pasteboard():
    return subprocess.run(["xcrun", "simctl", "pbpaste", udid()], capture_output=True, text=True).stdout


def clear_pasteboard():
    subprocess.run(["xcrun", "simctl", "pbcopy", udid()], input="", text=True, capture_output=True)


def labels(j):
    return [e.label for e in j.sim.find() if e.label]


def seed(j):
    return c.chat_seed(j, key="chatx_chat", turns=("ONE", "TWO", "THREE"))


def open_chat(j):
    st = seed(j)
    c.open_chat(j, st)
    return st


def page_menu(j):
    return c.page_menu(j)


def info(sid):
    return r.acpmux("_acpmux/info", {"sessionId": sid})


def ident(j, name, timeout=8):
    e = j.sim.wait(ident=name, timeout=timeout)
    check(e, f"no {name}; on screen: {labels(j)[:30]}")
    return e


def tap_ident(j, name, timeout=8, pause=1.0):
    j.sim.tap_el(ident(j, name, timeout))
    time.sleep(pause)


def back(j):
    b = [e for e in j.sim.find(kind="Button") if e.label in ("Back",) and e.frame[1] < 140]
    if b:
        j.sim.tap_el(b[0])
    else:
        j.sim.swipe(2, 400, 300, 400, 0.3)
    time.sleep(1.2)


def prompt_bubble(j, word):
    for _ in range(10):
        e = j.sim.wait(contains=f"the word {word}", timeout=4)
        if e and 120 < e.center[1] < 720:
            return e
        j.sim.swipe(200, 300, 200, 650, 0.4)
        time.sleep(1)
    check(False, f"no prompt bubble for {word}")


def answer_more(j):
    """The newest answer's More (the action row's ellipsis, under the answer, left of the middle)."""
    more = [e for e in j.sim.find(label="More", kind="Button") if 150 < e.center[1] < 740 and e.center[0] < 300]
    check(more, f"no answer More button: {[(e.label, e.frame) for e in j.sim.find(label='More')]}")
    return max(more, key=lambda e: e.center[1])


def hold(j, e):
    x, y = e.center
    j.sim.long_press(x, y, 1.2)
    time.sleep(1.5)


# ---------------------------------------------------------------- flows

def copy(j, label):
    """The page menu. After: Copy…, each row, read from the simulator's pasteboard and compared
    with the Mac's acpmux record of the chat (`_acpmux/info`)."""
    st = open_chat(j)
    out = {"menu": page_menu(j)}
    pq.shot(f"copy-{label}-menu")
    if label == "before":
        out["copy_rows"] = [x for x in out["menu"] if x.startswith("Copy")]
        c.dismiss(j)
        return out
    c.page_row(j, "Copy…")
    pq.shot("copy-after-sheet")
    mac = info(st["session"])
    out["mac_info"] = {k: mac.get(k) for k in ("name", "sessionId", "agentSessionId", "cwd")}
    copied = {}
    for row in ("agentName", "sessionID", "harnessSessionID", "conversation", "details", "workingDirectory", "host"):
        clear_pasteboard()
        tap_ident(j, f"chat.copy.{row}", pause=2.0)
        copied[row] = pasteboard()
    out["copied"] = copied
    pq.shot("copy-after-copied")
    out["matches"] = {
        "agentName": copied["agentName"] == (mac.get("name") or ""),
        "sessionID": copied["sessionID"] == st["session"],
        "harnessSessionID": copied["harnessSessionID"] == mac.get("agentSessionId"),
        "workingDirectory": copied["workingDirectory"] == mac.get("cwd"),
        "host": copied["host"] == pq.load()["mac_name"],
        "conversation_has_turns": all(w in copied["conversation"] for w in ("**User:**", "**Assistant:**", "TWO")),
    }
    tap_ident(j, "chat.copy.agentName", pause=0.2)
    done = j.sim.wait(label="Done", kind="Button", timeout=4)
    done and j.sim.tap_el(done)
    return out


def sessioninfo(j, label):
    """After: Session Info from the page menu: its rows against `_acpmux/info`."""
    st = open_chat(j)
    out = {"menu": page_menu(j)}
    if label == "before":
        out["has_session_info"] = "Session Info" in out["menu"]
        pq.shot("info-before-menu")
        c.dismiss(j)
        return out
    c.page_row(j, "Session Info")
    time.sleep(3)
    pq.shot("info-after-top")
    out["rows"] = [e.label for e in j.sim.find(ident="chat.info.*")]
    rows = {e.ident: e.label for e in j.sim.find() if (e.ident or "").startswith("chat.info.")}
    out["rows_by_id"] = rows
    j.sim.swipe(200, 650, 200, 250, 0.4)
    time.sleep(1.2)
    pq.shot("info-after-bottom")
    out["rows_by_id"].update({e.ident: e.label for e in j.sim.find() if (e.ident or "").startswith("chat.info.")})
    mac = info(st["session"])
    out["mac_info"] = {k: mac.get(k) for k in ("name", "sessionId", "agentSessionId", "cwd", "model")}
    return out


_COUNT = re.compile(r"^(\d+ turns|\d+ bookmarked|No bookmarked prompts|(Turn|Bookmark) \d+ of \d+)$")


def turn_count(j):
    """The turn bar's position text ("Turn 2 of 3", "3 turns")."""
    e = [x for x in j.sim.find() if _COUNT.match(x.label or "")]
    check(e, f"no turn bar text: {labels(j)[:40]}")
    return e[0].label


def tap_label(j, label, pause=1.2):
    e = j.sim.wait(label=label, kind="Button", timeout=6)
    check(e, f"no {label!r}: {labels(j)[:40]}")
    j.sim.tap_el(e)
    time.sleep(pause)


def turns(j, label):
    """Long-press the TWO prompt and an answer. After: Bookmark (acpmux `bookmark_get` holds the
    prompt's `user_message` seq), Pin on THREE's answer (its `turn_result` seq), then Jump to
    Turn: Previous/Next Turn and the bookmarked prompts only."""
    st = open_chat(j)
    sid = st["session"]
    out = {}
    bubble = prompt_bubble(j, "TWO")
    hold(j, bubble)
    out["prompt_menu"] = r.labels(j)
    pq.shot(f"turns-{label}-prompt-menu")
    if label == "before":
        out["has_bookmark"] = "Bookmark" in out["prompt_menu"]
        c.dismiss(j)
        out["page_menu"] = page_menu(j)
        out["has_jump"] = "Jump to Turn…" in out["page_menu"]
        c.dismiss(j)
        return out
    # Rig setup: start from no marks (an earlier run's are cleared on the Mac's own socket).
    for seq in r.acpmux("_acpmux/bookmark_get", {"sessionId": sid}).get("bookmarks") or []:
        r.acpmux("_acpmux/bookmark_set", {"sessionId": sid, "seq": seq, "bookmarked": False})
    c.dismiss(j)
    hold(j, prompt_bubble(j, "TWO"))
    out["marks_before"] = r.acpmux("_acpmux/bookmark_get", {"sessionId": sid}).get("bookmarks")
    r.tap(j, "Bookmark")
    time.sleep(2)
    prompts = c.events(sid, {"user_message"})
    seq_two = next(e["seq"] for e in prompts if "TWO" in (e["msg"].get("text") or ""))
    out["two_seq"] = seq_two
    out["marks_after_bookmark"] = r.acpmux("_acpmux/bookmark_get", {"sessionId": sid}).get("bookmarks")
    # Pin THREE's answer: its More menu.
    j.sim.swipe(200, 650, 200, 250, 0.4)
    time.sleep(1)
    more = [answer_more(j)]
    j.sim.tap_el(more[-1])
    time.sleep(1.2)
    out["answer_menu"] = r.labels(j)
    pq.shot("turns-after-answer-menu")
    r.tap(j, "Pin")
    time.sleep(2)
    out["marks_after_pin"] = r.acpmux("_acpmux/bookmark_get", {"sessionId": sid}).get("bookmarks")
    pinned = [m for m in out["marks_after_pin"] if m != seq_two]
    results = c.events(sid, {"turn_result"})
    out["pinned_record"] = next(({"seq": e["seq"], "kind": e["kind"], "turnId": e["msg"].get("turnId")} for e in results
                                 if pinned and e["seq"] == pinned[0]), None)
    # Jump to Turn.
    page_menu(j)
    c.page_row(j, "Jump to Turn…")
    time.sleep(1)
    out["bar"] = turn_count(j)
    pq.shot("turns-after-bar")
    steps = []
    for name in ("Previous Turn", "Previous Turn", "Previous Turn", "Previous Turn", "Next Turn"):
        tap_label(j, name)
        steps.append(turn_count(j))
    out["steps"] = steps
    pq.shot("turns-after-stepped")
    # Down to the newest turn, then back to the one bookmarked prompt above it.
    tap_label(j, "Next Turn")
    tap_label(j, "Next Turn")
    out["at_end"] = turn_count(j)
    tap_label(j, "Next Turn")
    out["past_end"] = turn_count(j)
    tap_label(j, "Bookmarked prompts only", pause=1)
    out["bookmarked_bar"] = turn_count(j)
    tap_label(j, "Previous Bookmarked Prompt", pause=1.5)
    out["bookmarked_step"] = turn_count(j)
    out["visible_after_bookmark_step"] = [e.label for e in j.sim.find(contains="the word") if 100 < e.center[1] < 400][:3]
    pq.shot("turns-after-bookmarked")
    tap_label(j, "Done")
    # Unbookmark from the phone again (acpmux's marks follow).
    hold(j, prompt_bubble(j, "TWO"))
    out["prompt_menu_after"] = r.labels(j)
    r.tap(j, "Remove Bookmark")
    time.sleep(2)
    out["marks_after_remove"] = r.acpmux("_acpmux/bookmark_get", {"sessionId": sid}).get("bookmarks")
    return out


def display(j, label):
    """After: Text and Width…: Zoom In twice and Standard width, read back as the transcript's
    text size; relaunched, the chat keeps it (saved per chat on this phone); Actual Size."""
    st = open_chat(j)
    bubble = prompt_bubble(j, "TWO") if label == "after" else None
    out = {"bubble_before": bubble.frame if bubble else None, "menu": page_menu(j)}
    pq.shot(f"display-{label}-menu")
    if label == "before":
        out["has_text_width"] = "Text and Width…" in out["menu"]
        c.dismiss(j)
        return out
    c.page_row(j, "Text and Width…")
    tap_ident(j, "chat.display.zoomIn", pause=0.8)
    tap_ident(j, "chat.display.zoomIn", pause=0.8)
    out["percent"] = ident(j, "chat.display.percent").label
    pq.shot("display-after-sheet")
    done = j.sim.wait(label="Done", kind="Button", timeout=4)
    j.sim.tap_el(done)
    time.sleep(1.5)
    pq.shot("display-after-zoomed")
    out["bubble_zoomed"] = prompt_bubble(j, "TWO").frame
    # Relaunch: the chat keeps its size.
    r.fresh(j)
    c.open_chat(j, st)
    time.sleep(2)
    out["bubble_relaunched"] = prompt_bubble(j, "TWO").frame
    pq.shot("display-after-relaunched")
    page_menu(j)
    c.page_row(j, "Text and Width…")
    out["percent_relaunched"] = ident(j, "chat.display.percent").label
    tap_ident(j, "chat.display.actualSize", pause=0.8)
    out["percent_reset"] = ident(j, "chat.display.percent").label
    j.sim.tap_el(j.sim.wait(label="Done", kind="Button", timeout=4))
    time.sleep(1.5)
    out["bubble_reset"] = prompt_bubble(j, "TWO").frame
    return out


def readaloud(j, label):
    """An answer's More menu. After: Read Aloud; while it reads the menu offers Stop Reading.
    The answer read is a long one (a paragraph asked for from the phone), so it is still
    reading when the menu opens again."""
    st = open_chat(j)
    if label == "after" and not j.sim.find(contains="lighthouse"):
        c.ask(j, "Write one paragraph of about 120 words about lighthouses.", "lighthouse", timeout=240)
        c.wait_idle(st["session"])
    j.sim.swipe(200, 650, 200, 250, 0.4)
    time.sleep(1)
    more = [answer_more(j)]
    j.sim.tap_el(more[-1])
    time.sleep(1.2)
    out = {"answer_menu": r.labels(j)}
    pq.shot(f"readaloud-{label}-menu")
    if label == "before":
        out["has_read_aloud"] = "Read Aloud" in out["answer_menu"]
        c.dismiss(j)
        return out
    r.tap(j, "Read Aloud")
    time.sleep(0.4)
    j.sim.tap_el(more[-1])
    time.sleep(1.0)
    out["menu_while_reading"] = r.labels(j)
    pq.shot("readaloud-after-reading")
    r.tap(j, "Stop Reading")
    time.sleep(0.6)
    j.sim.tap_el(more[-1])
    time.sleep(1.0)
    out["menu_after_stop"] = r.labels(j)
    c.dismiss(j)
    return out


def inspector(j, label):
    """After: Session Info > Event Inspector: the records the phone received for the chat, newest
    first, each one's JSON, compared with the Mac's own record of that seq."""
    st = open_chat(j)
    page_menu(j)
    if label == "before":
        out = {"menu": page_menu(j)}
        c.dismiss(j)
        return out
    c.page_row(j, "Session Info")
    time.sleep(2)
    j.sim.swipe(200, 650, 200, 250, 0.4)
    time.sleep(1)
    tap_ident(j, "chat.info.inspector", pause=2)
    out = {"count": ident(j, "chat.inspector.count").label}
    rows = j.sim.find(ident="chat.inspector.row")
    out["rows"] = [e.label for e in rows][:12]
    pq.shot("inspector-after-list")
    j.sim.tap_el(rows[0])
    time.sleep(1.5)
    out["json"] = (ident(j, "chat.inspector.json").label or "")[:1500]
    pq.shot("inspector-after-json")
    # The Mac's record of the same seq.
    seq = int(out["rows"][0].split("seq ")[-1].split(",")[0]) if "seq " in out["rows"][0] else None
    if seq:
        out["mac_record"] = next((e for e in c.events(st["session"], after=seq - 1) if e.get("seq") == seq), None)
    return out


def replay(j, label):
    """After: Session Info > Replay Conversation: the chat plays back from its start; the clock
    moves, Pause stops it, the scrubber goes back."""
    open_chat(j)
    if label == "before":
        out = {"menu": page_menu(j)}
        c.dismiss(j)
        return out
    page_menu(j)
    c.page_row(j, "Session Info")
    time.sleep(2)
    j.sim.swipe(200, 650, 200, 250, 0.4)
    time.sleep(1)
    tap_ident(j, "chat.info.replay", pause=1.5)
    out = {"clock": [], "visible": []}
    for i in range(4):
        out["clock"].append(ident(j, "chat.replay.clock").label)
        out["visible"].append([e.label for e in j.sim.find(contains="the word")][:4])
        pq.shot(f"replay-after-{i}")
        time.sleep(1.5)
    tap_ident(j, "chat.replay.speed", pause=0.3)
    out["speed"] = ident(j, "chat.replay.speed").value
    # Play at the end starts over; a second tap pauses: the clock then stays.
    tap_ident(j, "chat.replay.play", pause=1.5)
    out["restarted_clock"] = ident(j, "chat.replay.clock").label
    tap_ident(j, "chat.replay.play", pause=0.5)
    out["paused_clock"] = [ident(j, "chat.replay.clock").label]
    time.sleep(2.5)
    out["paused_clock"].append(ident(j, "chat.replay.clock").label)
    pq.shot("replay-after-paused")
    return out


_APPCALL = r"""
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
f.write(json.dumps({"id": 1, "method": sys.argv[2], "params": json.loads(sys.argv[3])}) + "\n"); f.flush()
print(f.readline())
"""


def app_call(method, params):
    """One call on the rig Mac app's own control socket (its DEBUG `debug.*` methods)."""
    res = pq.rsh(f"python3 -c {shlex.quote(_APPCALL)} /tmp/cmux-debug-{os.environ.get('PQ_TAG', 'chatx')}.sock "
                 f"{shlex.quote(method)} {shlex.quote(json.dumps(params))}", timeout=90)
    check(res.returncode == 0, f"{method}: {res.stderr.strip()[:300]}")
    return json.loads(res.stdout).get("result")


def grant_on_mac(j, st):
    """Rig setup: the phone asks the agent to run a command; on the Mac, the chat's own pane gives
    Allow for This Chat (only the person there may: `debug.agent_pane answer_permission`, the
    pane's own answer path)."""
    sid = st["session"]
    c.type_in_composer(j, "Use your Bash tool to run the command date, then reply with its output.")
    c.send(j)

    def asked():
        groups = r.acpmux("_acpmux/permission_groups", {"sessionId": sid}).get("groups") or []
        return [g for g in groups if g.get("state") == "pending"] or None
    t.until(asked, timeout=180, what="the agent's ask")
    tabs = json.loads(pq.RemoteMac().cmux("--json", "tab", "list", "--workspace", st["name"]).stdout)
    chat_tab = next(tab["id"] for tab in tabs if tab.get("content_kind") == "conversation")
    ws_id = next(w["id"] for w in json.loads(pq.RemoteMac().cmux("--json", "workspace", "list").stdout) if w.get("name") == st["name"])
    app_call("action.run", {"id": "goToWorkspace", "origin": "script", "args": {"workspace": ws_id}})
    time.sleep(3)
    # The pane's Always button, by a native click (an answer the page sends for a script is
    # refused: an Allow for This Chat is only the person's).
    pq.RemoteMac()._rmac("cli", "tab", chat_tab, "show")
    return app_call("debug.agent_pane", {"action": "click", "text": "Always"})


def permissions(j, label):
    """The Mac grants Allow for This Chat (rig setup, the Mac app's own pane: only the person
    there may). After: Session Info shows it on; Revoke Chat Permission, read back as acpmux's
    `chatAllowance` off and its `permission_chat_allowance` record; Refresh Permissions."""
    st = open_chat(j)
    sid = st["session"]
    out = {}
    if label == "after" and not (r.acpmux("_acpmux/permission_groups", {"sessionId": sid}).get("chatAllowance") or {}).get("active"):
        out["grant"] = grant_on_mac(j, st)
        time.sleep(3)
    out["groups_before"] = r.acpmux("_acpmux/permission_groups", {"sessionId": sid}).get("chatAllowance")
    if label == "before":
        out["menu"] = page_menu(j)
        c.dismiss(j)
        return out
    page_menu(j)
    c.page_row(j, "Session Info")
    time.sleep(2.5)
    j.sim.swipe(200, 650, 200, 300, 0.4)
    time.sleep(1)
    out["allow_row"] = ident(j, "chat.info.allowForChat").label
    pq.shot("permissions-after-on")
    tap_ident(j, "chat.info.revoke", pause=1.2)
    pq.shot("permissions-after-confirm")
    r.tap(j, "Revoke")
    time.sleep(2.5)
    out["allow_row_after"] = ident(j, "chat.info.allowForChat").label
    pq.shot("permissions-after-revoked")
    out["groups_after"] = r.acpmux("_acpmux/permission_groups", {"sessionId": sid}).get("chatAllowance")
    out["records"] = [e["msg"] for e in c.events(sid, {"permission_chat_allowance"})][-3:]
    tap_ident(j, "chat.info.refreshPermissions", pause=2)
    out["retry_enabled"] = ident(j, "chat.info.retryPermission").get("enabled")
    return out


def teams(j, label):
    """The grid's + menu. After: Launch Claude Teams: a new terminal tab on the Mac in the
    workspace, with the Mac's line typed into it (read back from the Mac's terminal screen)."""
    st = seed(j)
    t.open_ws(j, st["name"])
    pq.open_grid(j)
    j.sim.tap(62, 812)
    time.sleep(1.5)
    out = {"plus_menu": r.labels(j)}
    pq.shot(f"teams-{label}-menu")
    if label == "before":
        out["has_teams"] = [x for x in out["plus_menu"] if "Teams" in x]
        c.dismiss(j)
        return out
    before = [tab.get("surface") for _, tab in t.ws_tabs(t.mac_workspace(key=st["key"]))]
    r.tap(j, "Launch Claude Teams")

    def made():
        tabs = [tab for _, tab in t.ws_tabs(t.mac_workspace(key=st["key"])) if tab.get("surface") not in before]
        return tabs or None
    tabs, took = t.until(made, timeout=60, what="a new terminal tab on the Mac")
    out["new_tab"] = {k: tabs[0].get(k) for k in ("surface", "kind", "title")}
    out["new_tab_s"] = round(took, 1)
    time.sleep(6)
    screen = t.mac_raw({"cmd": "read-screen", "surface": tabs[0]["surface"]})
    out["screen"] = (screen.get("text") if isinstance(screen, dict) else str(screen))[-1500:]
    pq.shot("teams-after-terminal")
    return out


def chief(j, label):
    """Spotlight lists Message Chief (after); the intent opens the message box with its text,
    Send, read back from the Mac's Chief conversation."""
    u = udid()
    subprocess.run(["xcrun", "simctl", "terminate", u, pq.BUNDLE], capture_output=True)
    subprocess.run(["axe", "button", "home", "--udid", u], capture_output=True)
    time.sleep(2)
    j.sim.swipe(200, 400, 200, 650, 0.3)
    time.sleep(2)
    pq.type_text("Message Chief")
    time.sleep(4)
    out = {"spotlight": [e.label for e in j.sim.find() if e.label][:30]}
    pq.shot(f"chief-{label}-spotlight")
    subprocess.run(["axe", "button", "home", "--udid", u], capture_output=True)
    time.sleep(1)
    if label == "before":
        out["has_intent"] = any((e or "") == "Message Chief" for e in out["spotlight"])
        return out
    # A headless simulator's Spotlight opens the app without running an app's intent: the app
    # runs the same MessageChiefIntent.perform() from a DEBUG launch argument.
    text = f"Reply with exactly the word CHIEFX{int(time.time()) % 1000} and nothing else."
    j.sim.launch(pq.BUNDLE, args=("-cmux-mobile-run-intent", "message-chief"), env={"CMUX_MOBILE_INTENT_MESSAGE": text})
    field = j.sim.wait(ident="chief.messageAbout.field", timeout=30)
    check(field, f"no Message Chief sheet: {labels(j)[:20]}")
    out["field"] = field.value
    pq.shot("chief-after-sheet")
    tap_ident(j, "chief.messageAbout.send", pause=8)
    pq.shot("chief-after-sent")
    out["chief"] = c.chief_messages(6)
    return out


def cloudphoto(j, label):
    """Home > the Cloud Chief > + > Photos: a photo (rig setup put a checkerboard PNG in the
    simulator's library) with a line, Send. Before: the base app refuses it ("Photos can't be
    sent to Cloud Chief from iPhone yet."). After: it goes through the Cloud service's
    attachment routes and the message shows with its photo, delivered."""
    home = [e for e in j.sim.find(label="Home") if e.frame[1] > 700]
    check(home, "no Home tab")
    j.sim.tap_el(home[0])
    time.sleep(2.5)
    row = j.sim.wait(prefix="Chief, Main · Cloud", timeout=10)
    check(row, f"no Cloud Chief row: {labels(j)[:20]}")
    j.sim.tap_el(row)
    time.sleep(3)
    before_ids = {e.ident for e in j.sim.find() if (e.ident or "").startswith("conversation.message.")}
    tap_ident(j, "conversation.composer.plus", pause=1.5)
    j.sim.tap_el(j.sim.wait(label="Photos", kind="Button", timeout=5))
    time.sleep(2.5)
    allow = j.sim.wait(label="Allow Full Access", kind="Button", timeout=2)
    if allow:
        j.sim.tap_el(allow)
        time.sleep(2.5)
    # The newest photo (the checkerboard) is the grid's first cell.
    j.sim.tap(70, 605)
    time.sleep(2)
    pq.shot(f"cloudphoto-{label}-picked")
    field = ident(j, "conversation.composer.text")
    j.sim.tap_el(field)
    time.sleep(0.5)
    pq.type_text("Which colors are in this picture?")
    time.sleep(0.5)
    send = j.sim.wait(label="Send", kind="Button", timeout=5) or j.sim.wait(ident="conversation.composer.send", timeout=3)
    check(send, f"no Send: {labels(j)[-20:]}")
    j.sim.tap_el(send)
    time.sleep(8)
    out = {"after_send": [e.label for e in j.sim.find() if e.label and e.kind in ("StaticText", "Group", "GenericElement", "Button")][-25:]}
    out["new_messages"] = [e.label for e in j.sim.find() if (e.ident or "").startswith("conversation.message.") and e.ident not in before_ids]
    out["refusal"] = [e.label for e in j.sim.find(contains="can't be sent")]
    out["not_delivered"] = [e.label for e in j.sim.find(contains="Not Delivered")]
    pq.shot(f"cloudphoto-{label}-sent")
    time.sleep(20)
    out["later"] = [e.label for e in j.sim.find() if (e.ident or "").startswith("conversation.message.") and e.ident not in before_ids]
    pq.shot(f"cloudphoto-{label}-later")
    return out


FLOWS = {"cloudphoto": cloudphoto, "copy": copy, "info": sessioninfo, "turns": turns, "display": display, "readaloud": readaloud,
         "inspector": inspector, "replay": replay, "permissions": permissions, "teams": teams, "chief": chief}


def run(name, label):
    sim, mac, j = pq.ctx()
    if name != "chief":
        r.fresh(j)
    pq.rec_start(f"{name}-{label}")
    try:
        out = FLOWS[name](j, label)
    finally:
        pq.rec_stop()
    os.makedirs(pq.ART, exist_ok=True)
    json.dump(out, open(os.path.join(pq.ART, f"{name}-{label}.json"), "w"), indent=2, default=str)
    return out
