"""Chief conversation hooks parity flows (feat-cmux-next-ios-conversation-hooks-parity, cmux#25834):
Reply with Selection, Chief Zoom In / Zoom Out / Actual Size and Chat Colors on the phone's Chief.

Same rig as pq_chatx.py: the phone app in ONE headless simulator, the real tagged cmux-next Mac
app (rmac.py), the real link between them. Every action under test is done on the phone; the
reply is read back from the rig Mac's own Chief conversation (its session daemon).

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    . ~/cmux-next-ios-e2e/convhooks/env.sh && python3 -c 'import pq_convhooks as c; print(c.run("select", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import shlex
import subprocess
import time

import pq
from journey import Fail, check

SOURCE = "Deploy the build, then run the tests."


def udid():
    return pq.load()["udid"]


def labels(j):
    return [e.label for e in j.sim.find() if e.label]


def open_chief(j):
    """Home > the Mac's Chief (the rig Mac's own Chief over the link)."""
    j.back_to_list()
    j.tab("Home")
    tile = j.sim.wait(ident="home.chief.mac", timeout=90)
    check(tile, f"Home never showed the Mac's Chief: {labels(j)[:20]}")
    j.sim.tap_el(tile)
    t = time.time()
    while time.time() - t < 40:
        els = j.sim.tree()
        if not j.sim.find(ident="conversation.initialLoading", elements=els) and j.sim.find(ident="conversation.transcript", elements=els):
            time.sleep(1.5)
            return time.time() - t
        time.sleep(0.5)
    raise Fail("the Chief conversation never loaded")


_CHIEF = r"""
import json, socket, subprocess, sys
ps = subprocess.run(["ps", "-axwwo", "command"], capture_output=True, text=True).stdout.splitlines()
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
print(json.dumps([{"id": m.get("id"), "author": m.get("author"), "seq": m.get("seq"), "reply_to": m.get("reply_to"),
                   "text": " ".join(p.get("text", "") for p in m.get("parts", []) if p.get("type") == "text")[:600]}
                  for m in hist.get("messages", [])]))
"""


def chief_messages(limit=8):
    """The rig Mac Chief conversation's latest messages, read from its own session daemon."""
    tag_app = os.path.expanduser(f"{pq.RBASE}/rig/mac")
    res = pq.rsh(f"python3 -c {shlex.quote(_CHIEF)} {shlex.quote(tag_app)} {limit}", timeout=60)
    check(res.returncode == 0, f"chief history: {res.stderr.strip()[:300]}")
    return json.loads(res.stdout)


def bubbles(j, contains=None, chief=False):
    return [e for e in j.sim.find(contains=contains) if (e.ident or "").startswith("conversation.message.")
            and (not chief or (e.label or "").startswith("Chief,"))]


def type_and_send(j, text):
    field = j.sim.wait(ident="conversation.composer.text", timeout=10)
    check(field, "no composer")
    j.sim.tap_el(field)
    time.sleep(0.6)
    pq.type_text(text)
    time.sleep(0.6)
    send = j.sim.wait(ident="conversation.composer.send", timeout=5)
    check(send, "no Send")
    j.sim.tap_el(send)


def ensure_source(j, fresh=False):
    """A Chief message to quote, asked for over the link: with `fresh`, a new one (the newest
    bubble, just above the composer), else any Chief message with SOURCE on screen."""
    hit = bubbles(j, contains="run the tests", chief=True)
    if hit and not fresh:
        return hit[-1]
    token = f"build {int(time.time()) % 10000}"
    sentence = f"Deploy {token}, then run the tests."
    type_and_send(j, f"Reply with exactly this sentence and nothing else: {sentence}")
    t = time.time()
    while time.time() - t < 240:
        hit = bubbles(j, contains=token, chief=True)
        if hit:
            time.sleep(2)
            return hit[-1]
        time.sleep(1.5)
    raise Fail(f"Chief never answered with the source sentence: {labels(j)[-12:]}")


def dismiss_menu(j):
    subprocess.run(["axe", "key", "41", "--udid", udid()], capture_output=True)
    time.sleep(0.8)


def select_flow(j, label):
    """Long-press a Chief message > Select: the selected text's edit menu. After: Reply with
    Selection opens the reply to that message with the quote in the composer; Send; the Mac's
    Chief conversation has the reply, quote first, answering that message."""
    out = {"open_s": round(open_chief(j), 1)}
    src = ensure_source(j, fresh=True)
    out["source_bubble"] = src.label
    src_id = (src.ident or "").removeprefix("conversation.message.")
    pq.shot(f"select-{label}-source")
    x, y = src.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(1.5)
    pq.shot(f"select-{label}-longpress")
    sel = j.sim.wait(label="Select", timeout=6)
    check(sel, f"no Select in the long-press menu: {labels(j)[:30]}")
    j.sim.tap_el(sel)
    time.sleep(2.0)
    # The edit menu is not in the accessibility tree: read it from the screen.
    sx, sy, sw, sh = src.frame
    out["selection_menu"] = [o[4] for o in j.sim.ocr() if sy + sh - 10 < o[1] < sy + sh + 90]
    pq.shot(f"select-{label}-menu")
    has = j.sim.ocr_find("Reply with Selection", timeout=2)
    out["has_reply_with_selection"] = bool(has)
    if label == "before":
        dismiss_menu(j)
        return out
    check(has, f"no Reply with Selection: {out['selection_menu']}")
    x, y, w, h, _ = has[0]
    j.sim.tap(x + w / 2, y + h / 2)
    time.sleep(2.0)
    field = j.sim.wait(ident="conversation.composer.text", timeout=5)
    out["composer"] = field.value if field else None
    out["trailing"] = [e.label for e in j.sim.find(ident="conversation.header.trailing")]
    pq.shot(f"select-{label}-quoted")
    check(out["composer"] and out["composer"].startswith("> "), f"composer has no quote: {out['composer']!r}")
    before_ids = {m["id"] for m in chief_messages(8)}
    # The field has the keyboard focus already; a tap on its last (empty) line puts the
    # hardware keyboard's typing there, after the quote.
    fx, fy, fw, fh = field.frame
    j.sim.tap(fx + 30, fy + fh - 12)
    time.sleep(0.8)
    pq.type_text("That is the part I mean.")
    time.sleep(0.8)
    out["composer_typed"] = (j.sim.wait(ident="conversation.composer.text", timeout=3) or field).value
    pq.shot(f"select-{label}-typed")
    time.sleep(0.6)
    send = j.sim.wait(ident="conversation.composer.send", timeout=5)
    check(send, "no Send")
    j.sim.tap_el(send)
    t = time.time()
    sent = None
    while time.time() - t < 60 and not sent:
        time.sleep(1.5)
        sent = next((m for m in reversed(chief_messages(8)) if m["id"] not in before_ids and "That is the part I mean." in m["text"]), None)
    check(sent, "the reply never reached the Mac's Chief")
    out["mac_reply"] = sent
    out["source_id_on_phone"] = src_id
    time.sleep(2)
    pq.shot(f"select-{label}-sent")
    return out


def bubble_height(j):
    b = bubbles(j, contains="run the tests", chief=True) or bubbles(j)
    return round(b[-1].frame[3], 1) if b else None


def open_page_menu(j):
    tr = j.sim.wait(ident="conversation.header.trailing", timeout=8)
    check(tr, "no header trailing button")
    j.sim.tap_el(tr)
    time.sleep(1.5)


def tap_menu(j, title):
    e = j.sim.wait(label=title, timeout=6)
    check(e, f"no {title!r} in the menu: {labels(j)[:30]}")
    j.sim.tap_el(e)
    time.sleep(1.8)


def zoom_flow(j, label):
    """Chief's header button. Before: Invite to cmux's share sheet, no zoom anywhere. After: Chief's
    page menu with Invite to cmux and Zoom In / Zoom Out / Actual Size; Zoom In twice grows the
    transcript, the size stays after the app is quit and opened again, Actual Size resets it."""
    out = {"open_s": round(open_chief(j), 1)}
    ensure_source(j)
    out["trailing_label"] = [e.label for e in j.sim.find(ident="conversation.header.trailing")]
    out["height_rest"] = bubble_height(j)
    pq.shot(f"zoom-{label}-rest")
    open_page_menu(j)
    out["menu"] = labels(j)[:40]
    pq.shot(f"zoom-{label}-menu")
    if label == "before":
        out["has_zoom"] = any((x or "").startswith("Zoom") for x in out["menu"])
        close = j.sim.find(label="Close") or j.sim.find(label="Cancel")
        if close:
            j.sim.tap_el(close[0])
        else:
            dismiss_menu(j)
        time.sleep(1.5)
        return out
    tap_menu(j, "Zoom In")
    open_page_menu(j)
    tap_menu(j, "Zoom In")
    out["height_zoomed"] = bubble_height(j)
    pq.shot(f"zoom-{label}-zoomed")
    open_page_menu(j)
    out["menu_zoomed"] = [x for x in labels(j) if x.startswith(("Text Size", "Zoom", "Actual"))]
    pq.shot(f"zoom-{label}-menu-zoomed")
    dismiss_menu(j)
    # Saved on the phone: quit, open again, the Chief is still zoomed.
    j.sim.launch(pq.BUNDLE)
    time.sleep(4)
    open_chief(j)
    out["height_relaunched"] = bubble_height(j)
    pq.shot(f"zoom-{label}-relaunched")
    open_page_menu(j)
    out["menu_relaunched"] = [x for x in labels(j) if x.startswith(("Text Size", "Zoom", "Actual"))]
    tap_menu(j, "Actual Size")
    out["height_actual"] = bubble_height(j)
    pq.shot(f"zoom-{label}-actual")
    return out


def colors_flow(j, label):
    """Chief's page menu > Chat Colors…: the Mac's swatches for my and their bubbles. Picks show
    live under the sheet, stay after the app is quit and opened again (kept on this phone, per
    chat), and Reset brings Messages' colours back."""
    out = {"open_s": round(open_chief(j), 1)}
    ensure_source(j)
    pq.shot(f"colors-{label}-rest")
    open_page_menu(j)
    out["menu"] = [x for x in labels(j) if x in ("Invite to cmux", "Chat Colors…") or x.startswith(("Text Size", "Zoom", "Actual"))]
    pq.shot(f"colors-{label}-menu")
    if label == "before":
        out["has_chat_colors"] = "Chat Colors…" in out["menu"]
        dismiss_menu(j)
        return out
    tap_menu(j, "Chat Colors…")
    check(j.sim.wait(ident="chief.colors.sent.default", timeout=8), f"no Chat Colors sheet: {labels(j)[:30]}")
    pq.shot(f"colors-{label}-sheet")
    j.sim.tap_q(ident="chief.colors.sent.#34C759")
    time.sleep(1.2)
    j.sim.tap_q(ident="chief.colors.received.#1C2A4A")
    time.sleep(1.5)
    pq.shot(f"colors-{label}-picked")
    j.sim.tap_q(ident="chief.colors.done")
    time.sleep(1.5)
    out["done_closes_sheet"] = not j.sim.find(ident="chief.colors.sent.default")
    pq.shot(f"colors-{label}-applied")
    j.sim.launch(pq.BUNDLE)
    time.sleep(4)
    open_chief(j)
    pq.shot(f"colors-{label}-relaunched")
    open_page_menu(j)
    tap_menu(j, "Chat Colors…")
    j.sim.wait(ident="chief.colors.reset", timeout=8)
    reset = j.sim.find(ident="chief.colors.reset")
    out["reset_enabled"] = bool(reset) and reset[0].get("enabled") is True
    j.sim.tap_q(ident="chief.colors.reset")
    time.sleep(1.2)
    j.sim.tap_q(ident="chief.colors.done")
    time.sleep(1.5)
    out["done_closes_sheet_after_reset"] = not j.sim.find(ident="chief.colors.sent.default")
    pq.shot(f"colors-{label}-reset")
    return out


FLOWS = {"select": select_flow, "zoom": zoom_flow, "colors": colors_flow}


def run(name, label):
    sim, mac, j = pq.ctx()
    pq.rec_start(f"{name}-{label}")
    try:
        out = FLOWS[name](j, label)
    finally:
        pq.rec_stop()
    os.makedirs(pq.ART, exist_ok=True)
    json.dump(out, open(os.path.join(pq.ART, f"{name}-{label}.json"), "w"), indent=2, default=str)
    return out
