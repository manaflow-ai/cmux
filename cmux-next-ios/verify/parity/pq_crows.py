"""Chat row parity flows (feat-cmux-next-ios-chat-rows-parity, cmux#25834 slices A and C):
cmux slash commands (/status, /fork, /continue), Edit and Resend of an earlier prompt,
Resume of a paused queue, video and PDF attachments, Send Message… to the Chief about a
workspace or a tab, and the New Agent Chat shortcut.

Same rig as pq.py, pq_tabs.py and pq_rows.py: the phone app in ONE headless simulator, the
real tagged cmux-next Mac app (rmac.py), the real link between them. Every action under test
is done on the phone; after each one the Mac's state is read back from the rig app's own
acpmux socket (`_acpmux/sessions`, `_acpmux/events`), daemon socket (`list-workspaces`) or the
Chief's conversation (`cmux chat` on the Mac). The chats are started from the phone (acpmux
lets a phone control only a chat it started: D13), with their first prompts sent from the phone.

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    . ~/cmux-next-ios-e2e/crows/env.sh && python3 -c 'import pq_crows as c; print(c.run("slash", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import shlex
import subprocess
import time

import pq
import pq_rows as r
import pq_tabs as t
from journey import Fail, check

PREFIX = "crows-"


# ---------------------------------------------------------------- the Mac side

def sessions():
    return r.acpmux("_acpmux/sessions").get("sessions", [])


def session(sid):
    return next((s for s in sessions() if s.get("sessionId") == sid), None)


def events(sid, kinds=None, after=0):
    """The chat's records after seq `after` (all pages), optionally of `kinds`."""
    out, cursor = [], after
    for _ in range(40):
        page = r.acpmux("_acpmux/events", {"sessionId": sid, "afterSeq": cursor, "limit": 500})
        rows = page.get("events", page if isinstance(page, list) else [])
        if not rows:
            break
        out += rows
        cursor = max(e.get("seq", cursor) for e in rows)
        if not page.get("hasMore", len(rows) >= 500):
            break
    return [e for e in out if kinds is None or e.get("kind") in kinds]


def prompts(sid):
    """The chat's prompts as acpmux recorded them (`user_message` text and image names)."""
    return [{"text": e["msg"].get("text"), "images": [i.get("name") for i in e["msg"].get("images") or []],
             "seq": e.get("seq")} for e in events(sid, {"user_message"})]


def tab_sessions(ws_key):
    """{surface title: acpmux session} of a workspace's agent tabs (the Mac's daemon)."""
    ws = t.mac_workspace(key=ws_key)
    out = {}
    for _, tab in t.ws_tabs(ws):
        sess = ((tab.get("conversation") or {}).get("agent_session") or {}).get("session")
        if sess:
            out[f"{tab.get('surface')}: {tab.get('title')}"] = sess
    return out


# ---------------------------------------------------------------- the phone side

def labels(j):
    return r.labels(j)


def composer(j):
    f = j.sim.wait(kind="TextArea", timeout=4)
    if not f:
        # A chat with turns shows the composer collapsed ("Reply to <agent>"): a tap opens it.
        cap = [e for e in j.sim.find(kind="Button") if (e.label or "").startswith(("Reply to", "Ask "))]
        check(cap, f"no chat composer: {labels(j)[:20]}")
        j.sim.tap_el(cap[0])
        time.sleep(1)
        f = j.sim.wait(kind="TextArea", timeout=8)
    check(f, "no chat composer")
    return f


def type_in_composer(j, text):
    j.sim.tap_el(composer(j))
    time.sleep(0.6)
    pq.type_text(text)
    time.sleep(0.6)


def send(j):
    b = j.sim.wait(label="Send", kind="Button", timeout=5)
    check(b, "no Send button")
    j.sim.tap_el(b)
    time.sleep(1.0)


def wait_text(j, text, timeout=180, exclude=None):
    t0 = time.time()
    while time.time() - t0 < timeout:
        hits = [e for e in j.sim.find(contains=text) if e.kind not in ("TextArea", "TextView", "TextField")
                and not (exclude and exclude in (e.label or ""))]
        if hits:
            return round(time.time() - t0, 1)
        time.sleep(1)
    raise Fail(f"no {text!r} within {timeout} s")


def ask(j, prompt, expect, timeout=240):
    type_in_composer(j, prompt)
    send(j)
    return wait_text(j, expect, timeout=timeout, exclude="Reply with")


def wait_idle(sid, timeout=240):
    def idle():
        s = session(sid)
        return s if s and s.get("status") in ("ready", "idle") else None
    return t.until(idle, timeout=timeout, what="the chat to be idle")


def start_phone_chat(j, ws_name):
    """+ > New Agent Chat With… > Claude Code > Start Chat, on the phone, in workspace `ws_name`."""
    t.open_ws(j, ws_name)
    before = {s["sessionId"] for s in sessions()}
    pq.plus_menu(j, "New Agent Chat With…")
    row = j.sim.wait(prefix="Claude Code", kind="Button", timeout=15)
    check(row, "no Claude Code row")
    j.sim.tap_el(row)
    time.sleep(0.8)
    j.sim.tap_el(j.sim.wait(label="Start Chat", kind="Button", timeout=5))
    pq.wait_opened(j, timeout=120)
    return before


def chat_seed(j, key="crows_chat", turns=("ONE", "TWO", "THREE")):
    """A phone-started Claude chat in a `crows-chat-*` workspace with one answered turn per
    word in `turns` (each prompt sent from the phone). Kept in the state file."""
    st = pq.load().get(key)
    if st and t.mac_workspace(key=st["key"]) and session(st["session"]):
        return st
    ws = t.seed(f"{key.replace('_', '-')}", terminals=1)
    before = start_phone_chat(j, ws["name"])
    sid = None
    for word in turns:
        took = ask(j, f"Reply with exactly the word {word} and nothing else.", word)
        if sid is None:
            made = [s for s in sessions() if s["sessionId"] not in before]
            check(made, "the phone's chat never reached acpmux")
            sid = made[0]["sessionId"]
        pq.log(f"{word}: {took} s")
        wait_idle(sid)
    st = {"name": ws["name"], "key": ws["key"], "session": sid}
    full = pq.load()
    full[key] = st
    pq.save(full)
    return st


def open_chat(j, st):
    """The seeded chat's page in its workspace."""
    t.open_ws(j, st["name"])
    if j.sim.find(kind="TextArea") or [e for e in j.sim.find(kind="Button") if (e.label or "").startswith("Reply to")]:
        return
    pq.open_grid(j)
    cards = [e for e in j.sim.find(suffix=", tab") if not (e.label or "").startswith("p2tabs-t")]
    check(cards, "no chat card")
    j.sim.tap_el(cards[0])
    time.sleep(2.5)


def page_menu(j):
    """The page menu: a tap on the title capsule at the bottom (pq_panes.open_page_menu)."""
    import pq_panes
    return pq_panes.open_page_menu(j)


def page_row(j, label):
    import pq_panes
    pq_panes.tap_row(j, label)


def dismiss(j):
    r.dismiss(j)


# ---------------------------------------------------------------- flows

def slash(j, label):
    """Types `/` in a phone-started chat's composer: the slash list. After: /status opens the
    session's status (acpmux `_acpmux/info`), /fork opens a copy of the chat in a new tab
    (acpmux `session/fork`, read back as a new session and a new agent tab on the Mac), and
    /continue lists the agents it can continue in."""
    st = chat_seed(j)
    open_chat(j, st)
    type_in_composer(j, "/")
    out = {"slash_rows": [e.label for e in j.sim.find() if (e.label or "").startswith("/")][:20]}
    pq.shot(f"slash-{label}-list")
    if label == "before":
        out["has_cmux"] = [n for n in ("/status", "/fork", "/continue") if any((x or "").startswith(n) for x in out["slash_rows"])]
        return out
    # /status
    pq.type_text("status")
    time.sleep(0.5)
    send(j)
    check(j.sim.wait(label="Session Status", timeout=15), "no Session Status sheet")
    time.sleep(2)
    out["status_fields"] = [e.label for e in j.sim.find(ident="chat.status.*")]
    pq.shot("slash-after-status")
    shown = next((f.split(", ", 1)[1] for f in out["status_fields"] if f.startswith("Session, ")), None)
    info = r.acpmux("_acpmux/info", {"sessionId": shown or st["session"]})
    out["mac_info"] = {"sessionId": info.get("sessionId"), "cwd": info.get("cwd"), "model": info.get("model"),
                       "effort": info.get("effort")}
    j.sim.tap_el(j.sim.wait(label="Done", kind="Button", timeout=5))
    time.sleep(1)
    # /fork
    before_ids = {s["sessionId"] for s in sessions()}
    before_tabs = tab_sessions(st["key"])
    type_in_composer(j, "/fork")
    send(j)

    def forked():
        made = [s for s in sessions() if s["sessionId"] not in before_ids]
        tabs = tab_sessions(st["key"])
        return {"session": made[0]["sessionId"], "tabs": tabs} if made and len(tabs) > len(before_tabs) else None
    out["fork"], took = t.until(forked, timeout=120, what="a fork on the Mac")
    out["fork_s"] = round(took, 1)
    out["tabs_before"] = before_tabs
    time.sleep(3)
    pq.shot("slash-after-fork")
    # /continue (back on the original chat's tab: the fork is in front now)
    open_chat(j, st)
    type_in_composer(j, "/continue")
    send(j)
    time.sleep(4)
    out["continue_screen"] = [e.label for e in j.sim.find() if e.label and e.kind in ("StaticText", "Button")][:25]
    pq.shot("slash-after-continue")
    return out


def edit(j, label):
    """Long-presses the chat's second prompt. After: Edit and Resend, an edited prompt, Send:
    a copy of the chat through the first turn (acpmux `acp.session.fork {throughSeq}`) opens
    in a new tab and runs the edited prompt; the Mac's new session holds the first prompt and
    the edited one, the original chat is unchanged."""
    st = chat_seed(j, key="crows_edit")
    open_chat(j, st)
    original = prompts(st["session"])
    out = {"original_prompts": [p["text"] for p in original]}
    bubble = j.sim.wait(contains="the word TWO", timeout=10)
    if not bubble:
        j.sim.swipe(200, 300, 200, 650, 0.4)
        time.sleep(1)
        bubble = j.sim.wait(contains="the word TWO", timeout=10)
    check(bubble, "no second prompt bubble")
    x, y = bubble.center
    j.sim.long_press(x, y, 1.2)
    time.sleep(1.5)
    out["menu"] = labels(j)
    pq.shot(f"edit-{label}-menu")
    if label == "before":
        out["has_edit"] = "Edit and Resend" in out["menu"]
        dismiss(j)
        return out
    r.tap(j, "Edit and Resend")
    field = j.sim.wait(ident="chat.editEarlier.field", timeout=8)
    check(field, "no edit sheet")
    pq.shot("edit-after-sheet")
    # Replace TWO with TWENTY at the end of the prompt: the caret is at the end.
    for _ in range(len("TWO and nothing else.")):
        subprocess.run(["axe", "key", "42", "--udid", pq.load()["udid"]], capture_output=True)
    pq.type_text("TWENTY and nothing else.")
    time.sleep(0.8)
    pq.shot("edit-after-edited")
    before_ids = {s["sessionId"] for s in sessions()}
    j.sim.tap_el(j.sim.wait(ident="chat.editEarlier.send", timeout=5))

    def forked():
        made = [s for s in sessions() if s["sessionId"] not in before_ids]
        return made[0]["sessionId"] if made else None
    sid, took = t.until(forked, timeout=120, what="the edit's fork on the Mac")
    out["fork_session"] = sid
    out["fork_s"] = round(took, 1)
    wait_text(j, "TWENTY", timeout=240, exclude="Reply with")
    time.sleep(2)
    pq.shot("edit-after-answer")
    out["fork_prompts"] = [p["text"] for p in prompts(sid)]
    out["fork_meta"] = {k: (session(sid) or {}).get(k) for k in ("forkedFrom", "parentSessionId", "forkedAtSeq")}
    out["original_after"] = [p["text"] for p in prompts(st["session"])]
    return out


def queue(j, label):
    """A long turn runs; a second prompt waits in the queue; the turn fails (the Mac ends its
    agent, rig setup): acpmux pauses the queue. After: the phone's Resume, read back as
    acpmux's `queue_resumed` and the held prompt's turn."""
    st = chat_seed(j, key="crows_queue", turns=("ONE",))
    open_chat(j, st)
    sid = st["session"]
    last = max([e.get("seq", 0) for e in events(sid)] or [0])
    type_in_composer(j, "Write a detailed 2500-word story about a lighthouse keeper, then reply DONE.")
    send(j)
    time.sleep(4)
    type_in_composer(j, "Reply with exactly the word QUEUED and nothing else.")
    send(j)
    time.sleep(2)
    # The turn's agent process dies on the Mac (rig setup: SIGKILL of the chat's Claude Code, by
    # its own session id): the turn fails and acpmux holds the prompts behind it.
    agent = (session(sid) or {}).get("agentSessionId")
    check(agent, "no agent session id")
    pids = pq.rsh(f"pgrep -f {shlex.quote(agent)} || true").stdout.split()
    out = {"agent_pids": pids}
    check(pids, "the chat's agent process is not running")
    pq.rsh("kill -9 " + " ".join(pids))

    def paused():
        rows = events(sid, {"queue_paused", "queue_resumed", "turn_result"}, after=last)
        return rows if any(e["kind"] == "queue_paused" for e in rows) else None
    out["paused"], _ = t.until(paused, timeout=120, what="acpmux to pause the queue")
    time.sleep(3)
    pq.shot(f"queue-{label}-paused")
    out["phone"] = [e.label for e in j.sim.find() if e.label and ("Paused" in e.label or "QUEUED" in e.label or e.label == "Resume")]
    if label == "before":
        out["has_resume"] = bool(j.sim.find(label="Resume"))
        return out
    b = j.sim.wait(ident="chat.queue.resume", timeout=5) or j.sim.wait(label="Resume", timeout=3)
    check(b, "no Resume")
    j.sim.tap_el(b)

    def resumed():
        rows = events(sid, {"queue_resumed", "user_message"}, after=last)
        return rows if any(e["kind"] == "queue_resumed" for e in rows) else None
    out["resumed"], took = t.until(resumed, timeout=60, what="acpmux to resume the queue")
    out["resumed_s"] = round(took, 1)
    wait_text(j, "QUEUED", timeout=240, exclude="Reply with")
    pq.shot("queue-after-resumed")
    out["prompts_after"] = [p["text"] for p in prompts(sid)][-3:]
    return out


def video(j, label):
    """+ > Photos: the picker. Before: images only (the simulator's library holds a video, rig
    setup, which it does not list). After: the video is picked; the prompt reaches acpmux with
    the video's link, its frames note and its frames (image names)."""
    st = chat_seed(j, key="crows_media", turns=("ONE",))
    udid = pq.load()["udid"]
    clip = os.path.expanduser("~/cmux-next-ios-e2e/crows/clip.mp4")
    if not pq.load().get("clip_added"):
        subprocess.run(["xcrun", "simctl", "addmedia", udid, clip], capture_output=True)
        full = pq.load()
        full["clip_added"] = True
        pq.save(full)
    open_chat(j, st)
    j.sim.tap_el(j.sim.wait(label="Add", kind="PopUpButton", timeout=8))
    time.sleep(1.2)
    r.tap(j, "Photos")
    time.sleep(5)
    pq.shot(f"video-{label}-picker")
    # A video's cell shows its length (0:NN) over the thumbnail.
    lengths = [h for h in j.sim.ocr() if h[4].strip().startswith("0:") and len(h[4].strip()) <= 5]
    out = {"video_cells": [h[4] for h in lengths]}
    if label == "before":
        ocr_tap(j, "Cancel", timeout=3) if j.sim.ocr_find("Cancel") else j.sim.tap(363, 110)
        return out
    check(lengths, "no video in the picker")
    x, y, w, h, _ = lengths[0]
    j.sim.tap(x - 30, y - 40)
    time.sleep(1.5)
    pq.shot("video-after-selected")
    # The picker's Done: the check at its top right.
    j.sim.tap(363, 144)
    time.sleep(8)
    pq.shot("video-after-attached")
    out["chip"] = [e.label for e in j.sim.find(ident="attachment.thumb")]
    last = max([e.get("seq", 0) for e in events(st["session"])] or [0])
    type_in_composer(j, "What app is shown in this video? Answer in one short sentence.")
    send(j)

    def sent():
        rows = [e for e in events(st["session"], {"user_message"}, after=last)]
        return rows[-1]["msg"] if rows else None
    msg, took = t.until(sent, timeout=240, what="the video prompt on the Mac")
    out["mac_parts"] = [{k: p.get(k) for k in ("kind", "name", "text", "mimeType", "size") if p.get(k) is not None}
                        for p in msg.get("inlineParts") or []]
    out["mac_images"] = [i.get("name") for i in msg.get("images") or []]
    out["sent_s"] = round(took, 1)
    time.sleep(15)
    pq.shot("video-after-sent")
    out["bubble"] = [e.label for e in j.sim.find(kind="StaticText") if e.label][-6:]
    return out


def ocr_tap(j, needle, timeout=8.0, below=0):
    """Taps text in an out-of-process screen (the system's Files or Photos picker, whose
    views are not in the app's accessibility tree), read with Vision."""
    hits = [h for h in j.sim.ocr_find(needle, timeout=timeout) if h[1] >= below]
    check(hits, f"no {needle!r} on screen")
    x, y, w, h, _ = hits[0]
    j.sim.tap(x + w / 2, y + h / 2)
    time.sleep(1.5)


def pdf(j, label):
    """A PDF in the simulator's On My iPhone (rig setup), attached from + > Files. Before and
    after the same gesture; acpmux's record of the prompt says how it went: before, a link to
    an uploaded copy (`file` part); after, a `document` part the model reads."""
    st = chat_seed(j, key="crows_media", turns=("ONE",))
    udid = pq.load()["udid"]
    src = os.path.expanduser("~/cmux-next-ios-e2e/crows/brief.pdf")
    if not os.path.exists(src):
        with open(src, "wb") as out_pdf:
            subprocess.run(["/usr/sbin/cupsfilter", "-i", "text/plain", "-m", "application/pdf", "/etc/hosts"],
                           stdout=out_pdf, stderr=subprocess.DEVNULL)
    groups = subprocess.run(["xcrun", "simctl", "get_app_container", udid, "com.apple.DocumentsApp", "groups"],
                            capture_output=True, text=True).stdout
    local = next(line.split("\t", 1)[1] for line in groups.splitlines() if line.startswith("group.com.apple.FileProvider.LocalStorage"))
    os.makedirs(f"{local}/File Provider Storage", exist_ok=True)
    subprocess.run(["cp", src, f"{local}/File Provider Storage/brief.pdf"])
    open_chat(j, st)
    j.sim.tap_el(j.sim.wait(label="Add", kind="PopUpButton", timeout=8))
    time.sleep(1.2)
    r.tap(j, "Files")
    time.sleep(4)
    out = {}
    ocr_tap(j, "Browse", below=700)
    if not j.sim.ocr_find("brief", timeout=2):
        ocr_tap(j, "On My iPhone")
    pq.shot(f"pdf-{label}-files")
    # The file's tile: its size line reads clearly ("15 KB"); the name over it is small.
    size = [h for h in j.sim.ocr_find(" KB", timeout=8) if h[1] > 200]
    check(size, "no file tile in On My iPhone")
    x, y, w, h, _ = size[0]
    j.sim.tap(x + w / 2, y - 80)
    time.sleep(1.5)
    # The composer's Files takes several files: a tap selects, Open attaches.
    if j.sim.ocr_find("Open", timeout=3):
        ocr_tap(j, "Open")
    time.sleep(3)
    out["chip"] = [e.label for e in j.sim.find(ident="attachment.thumb")]
    pq.shot(f"pdf-{label}-attached")
    last = max([e.get("seq", 0) for e in events(st["session"])] or [0])
    type_in_composer(j, "What is the first word of this PDF? Reply with that word only.")
    send(j)

    def sent():
        rows = [e for e in events(st["session"], {"user_message"}, after=last)]
        return rows[-1]["msg"] if rows else None
    msg, took = t.until(sent, timeout=180, what="the PDF prompt on the Mac")
    out["mac_parts"] = [{k: p.get(k) for k in ("kind", "name", "mimeType", "size", "uri", "path") if p.get(k) is not None}
                        for p in msg.get("inlineParts") or []]
    out["sent_s"] = round(took, 1)
    time.sleep(12)
    pq.shot(f"pdf-{label}-sent")
    out["answer"] = [e.label for e in j.sim.find(kind="StaticText") if e.label][-4:]
    return out


_CHIEF = r"""
import glob, json, os, socket, subprocess, sys
# The rig app's Chief session daemon: the headless cmux-tui the app runs with `--session cmux-chief-*`.
ps = subprocess.run(["ps", "-axwwo", "command"], capture_output=True, text=True).stdout.splitlines()
# The daemon's own command line (not this script's, which names the same words).
line = next(l for l in ps if l.startswith(sys.argv[1]) and " --session cmux-chief-" in l)
path = line.split("--socket ", 1)[1].split(" --")[0].strip()
s = socket.socket(socket.AF_UNIX); s.connect(path); f = s.makefile("rw")
def ask(i, req):
    f.write(json.dumps(dict(req, id=i)) + "\n"); f.flush()
    while True:
        m = json.loads(f.readline())
        if m.get("id") == i: return m.get("data", m)
conv = ask(1, {"cmd": "conversation-list"})["conversations"]
chief = next(c for c in conv if any(p.get("agent_class") == "mux" for p in c.get("participants", [])))
hist = ask(2, {"cmd": "conversation-snapshot", "conversation": chief["id"], "tail": int(sys.argv[2])})
print(json.dumps([{"author": m.get("author"), "seq": m.get("seq"),
                   "text": " ".join(p.get("text", "") for p in m.get("parts", []) if p.get("type") == "text")[:400]}
                  for m in hist.get("messages", [])]))
"""


def chief_messages(limit=6):
    """The rig Mac Chief conversation's latest messages, read from its own session daemon."""
    tag_app = os.path.expanduser(f"{pq.RBASE}/rig/mac")
    res = pq.rsh(f"python3 -c {shlex.quote(_CHIEF)} {shlex.quote(tag_app)} {limit}", timeout=60)
    check(res.returncode == 0, f"chief history: {res.stderr.strip()[:300]}")
    return json.loads(res.stdout)


def message(j, label):
    """A workspace row's menu and a tab's page menu. After: Send Message…: a message to the Chief
    starting with the workspace's (then the tab's) cmux link, read back from the Mac's Chief
    conversation."""
    ws = t.seed("crows-msg", terminals=1)
    out = {}
    row = r.list_row(j, ws["name"])
    r.hold(j, row)
    out["row_menu"] = labels(j)
    pq.shot(f"message-{label}-row-menu")
    if label == "before":
        out["row_has"] = "Send Message…" in out["row_menu"]
        dismiss(j)
        t.open_ws(j, ws["name"])
        pq.open_grid(j)
        j.sim.tap_el(t.card(j, "p2tabs-t1"))
        time.sleep(2)
        out["page_menu"] = page_menu(j)
        out["page_has"] = "Send Message…" in out["page_menu"]
        pq.shot("message-before-page-menu")
        dismiss(j)
        return out
    r.tap(j, "Send Message…")
    field = j.sim.wait(ident="chief.messageAbout.field", timeout=8)
    check(field, "no Message Chief sheet")
    j.sim.tap_el(field)
    pq.type_text("Which tabs are open in this workspace?")
    time.sleep(0.6)
    pq.shot("message-after-sheet")
    j.sim.tap_el(j.sim.wait(ident="chief.messageAbout.send", timeout=5))
    time.sleep(6)
    pq.shot("message-after-chief")
    out["chief_after_workspace"] = chief_messages()
    t.open_ws(j, ws["name"])
    pq.open_grid(j)
    j.sim.tap_el(t.card(j, "p2tabs-t1"))
    time.sleep(2)
    out["page_menu"] = page_menu(j)
    pq.shot("message-after-page-menu")
    page_row(j, "Send Message…")
    field = j.sim.wait(ident="chief.messageAbout.field", timeout=8)
    check(field, "no Message Chief sheet from the tab")
    j.sim.tap_el(field)
    pq.type_text("What is running in this terminal?")
    j.sim.tap_el(j.sim.wait(ident="chief.messageAbout.send", timeout=5))
    time.sleep(6)
    pq.shot("message-after-chief-tab")
    out["chief_after_tab"] = chief_messages()
    tree = t.mac_workspace(key=ws["key"])
    out["mac_ids"] = {"workspace": tree.get("resource_id") or tree.get("id"),
                      "tab": [tab.get("tab_id") or tab.get("resource_id") for _, tab in t.ws_tabs(tree)]}
    return out


def shortcut(j, label):
    """Spotlight on the simulator's Home Screen: "New Agent Chat". After: the app's shortcut runs,
    cmux opens a new agent chat workspace (read back from the Mac's workspace list) with the
    composer up."""
    udid = pq.load()["udid"]
    before = {w.get("key") for w in t.mac_tree().get("workspaces", [])}
    subprocess.run(["xcrun", "simctl", "terminate", udid, pq.BUNDLE], capture_output=True)
    subprocess.run(["axe", "button", "home", "--udid", udid], capture_output=True)
    time.sleep(2)
    j.sim.swipe(200, 400, 200, 650, 0.3)
    time.sleep(2)
    pq.type_text("New Agent Chat")
    time.sleep(4)
    out = {"spotlight": [e.label for e in j.sim.find() if e.label][:30]}
    pq.shot(f"shortcut-{label}-spotlight")
    if label == "before":
        out["has_shortcut"] = any("New Agent Chat" == (e or "") for e in out["spotlight"])
        subprocess.run(["axe", "button", "home", "--udid", udid], capture_output=True)
        return out
    hit = j.sim.wait(label="New Agent Chat", timeout=8) or j.sim.wait(contains="New Agent Chat", timeout=4)
    check(hit, "no New Agent Chat in Spotlight")
    out["listed"] = True
    # A headless simulator's Spotlight opens the app without running an app's intent (Call Chief
    # alike): the app runs the same NewAgentChatIntent.perform() from a DEBUG launch argument.
    subprocess.run(["axe", "button", "home", "--udid", udid], capture_output=True)
    time.sleep(1)
    j.sim.launch(pq.BUNDLE, args=("-cmux-mobile-run-intent", "new-agent-chat"),
                 env={"CMUX_MOBILE_INTENT_MESSAGE": "Reply with exactly the word SHORTCUT and nothing else."})

    def made():
        new = [w for w in t.mac_tree().get("workspaces", []) if w.get("key") not in before]
        return new or None
    new, took = t.until(made, timeout=120, what="the new agent chat workspace on the Mac")
    out["new_workspace"] = [{"name": w.get("name") or w.get("title"), "kinds": [tab.get("kind") for _, tab in t.ws_tabs(w)]} for w in new]
    out["new_s"] = round(took, 1)
    time.sleep(6)
    pq.shot("shortcut-after-chat")
    out["composer"] = [(e.label, e.value) for e in j.sim.find(kind="TextArea")]
    return out


def stopall(j, label):
    """Two chats working on the Mac at once: one the phone started (a long turn sent from the
    phone) and one the Mac started (rig setup, over its local acpmux socket). The Agent Chats
    list's Filter menu. After: Stop All Agents, confirmed: acpmux ends the phone's chat's turn
    (`turn_result` cancelled) and keeps the Mac's running (only its owner stops it), and the
    phone says so."""
    st = chat_seed(j, key="crows_stop", turns=("ONE",))
    long = "Write a detailed 3000-word story about a lighthouse keeper, then reply DONE."
    open_chat(j, st)
    type_in_composer(j, long)
    send(j)
    folder = pq.rsh(f"cd {t.PROJ} && pwd -P").stdout.strip()
    made = r.acpmux("session/new", {"cwd": folder, "mcpServers": [], "_meta": {"acpmux": {"harness": "claude", "policy": "approve-all"}}})
    mac_sid = made["sessionId"]
    # The Mac's prompt, sent and left running (a notification-like request that returns once queued).
    pq.rsh(f"python3 -c {shlex.quote(r._ACPMUX)} {shlex.quote(os.environ['PQ_ACPMUX_SOCK'])} session/prompt "
           f"{shlex.quote(json.dumps({'sessionId': mac_sid, 'prompt': [{'type': 'text', 'text': long}]}))} >/dev/null 2>&1 &", timeout=10)

    def both_running():
        a, b = session(st["session"]) or {}, session(mac_sid) or {}
        return (a.get("status"), b.get("status")) if a.get("status") == "running" and b.get("status") == "running" else None
    out = {"before_status": t.until(both_running, timeout=120, what="both chats working")[0], "mac_session": mac_sid}
    pq.open_grid(j) if not j.sim.find(label="Page Menu") else None
    page_menu(j)
    page_row(j, "Search Agent Chats")
    time.sleep(3)
    f = j.sim.wait(ident="agentChats.filter", timeout=10) or j.sim.wait(label="Filter", timeout=5)
    check(f, "no Agent Chats filter")
    j.sim.tap_el(f)
    time.sleep(1.2)
    out["filter_menu"] = labels(j)
    pq.shot(f"stopall-{label}-menu")
    if label == "before":
        out["has_stop_all"] = "Stop All Agents" in out["filter_menu"]
        dismiss(j)
        r.acpmux("session/cancel", {"sessionId": mac_sid})
        r.acpmux("session/cancel", {"sessionId": st["session"]})
        return out
    r.tap(j, "Stop All Agents")
    time.sleep(1)
    pq.shot("stopall-after-confirm")
    out["confirm"] = labels(j)
    # The confirmation (a popover from the menu's button): its Stop All Agents.
    check(j.sim.find(contains="Each agent stops its current turn"), "no confirmation")
    buttons = j.sim.find(label="Stop All Agents", kind="Button")
    check(buttons, "no confirmation button")
    j.sim.tap_el(buttons[-1])

    def phone_stopped():
        s1 = session(st["session"]) or {}
        return s1 if s1.get("status") != "running" and (s1.get("lastTurn") or {}).get("status") == "cancelled" else None
    stopped, took = t.until(phone_stopped, timeout=60, what="the phone's chat to stop")
    out["phone_chat_after"] = {"status": stopped.get("status"), "lastTurn": (stopped.get("lastTurn") or {}).get("status")}
    out["stop_s"] = round(took, 1)
    m = session(mac_sid) or {}
    out["mac_chat_after"] = {"status": m.get("status")}
    time.sleep(2)
    out["alert"] = [e.label for e in j.sim.find() if e.label and ("Stopped" in e.label or "owner" in e.label)]
    pq.shot("stopall-after-result")
    r.acpmux("session/cancel", {"sessionId": mac_sid})
    return out


FLOWS = {"stopall": stopall, "slash": slash, "edit": edit, "queue": queue, "video": video, "pdf": pdf, "message": message, "shortcut": shortcut}


def run(name, label):
    sim, mac, j = pq.ctx()
    if name != "shortcut":
        r.fresh(j)
    pq.rec_start(f"{name}-{label}")
    try:
        out = FLOWS[name](j, label)
    finally:
        pq.rec_stop()
    os.makedirs(pq.ART, exist_ok=True)
    json.dump(out, open(os.path.join(pq.ART, f"{name}-{label}.json"), "w"), indent=2, default=str)
    return out
