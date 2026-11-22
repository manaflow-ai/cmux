"""Terminal parity flows (feat-cmux-next-ios-terminal-parity): a tapped link opens a cmux
browser tab beside the terminal, Find… over the scrollback, and Clear that clears the Mac's
scrollback. Same rig as pq.py and pq_tabs.py: the phone app in ONE headless simulator, the
real tagged cmux-next Mac app (rmac.py), the real link between them. The Mac side is seeded
with output (`send`) and read back (`list-workspaces`, `read-scrollback`) on its own daemon
socket; every action under test is done on the phone.

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    PQ_HOST=local PQ_RBASE=~/cmux-next-ios-e2e/tp PQ_TAG=<rig tag> PQ_SIM=tp-phone \\
    PQ_STATE=~/cmux-next-ios-e2e/tp/state.json PQ_RAW=~/cmux-next-ios-e2e/tp/raw \\
    python3 -c 'import pq_terminal as t; print(t.run("link", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import time

import pq
import pq_tabs as t
from journey import Fail, check


def seed(flow):
    """A `tp-<flow>-HHMMSS` workspace with one terminal; returns (name, surface)."""
    ws = t.seed(f"tp-{flow}", terminals=1)
    name = ws.get("name") or ws.get("title")
    return name, t.ws_tabs(ws)[0][1]["surface"]


def type_on_mac(surface, line):
    """Output for the flow, typed into the Mac terminal by the rig (setup, not the action)."""
    t.mac_raw({"cmd": "send", "surface": surface, "text": line + "\r"})


def history_rows(surface):
    """The Mac terminal's retained scrollback rows (`read-scrollback` total)."""
    return int(t.mac_raw({"cmd": "read-scrollback", "surface": surface, "start": 0, "count": 0}).get("total", 0))


def ocr_text(j):
    return " | ".join(o[4] for o in j.sim.ocr())


def open_terminal(j, name):
    t.open_ws(j, name)
    time.sleep(2.0)


def link(j, label):
    """A tap on a URL printed in the terminal: after, the Mac opens a browser tab at it in the
    same workspace's pane and the phone shows it; before, nothing opens."""
    name, surface = seed("link")
    stamp = time.strftime("%H%M%S")
    # The command line says $((1)); only the output has the whole URL.
    type_on_mac(surface, f'echo "docs: https://example.com/$((1))cmux-link-{stamp} ok"')
    open_terminal(j, name)
    needle = f"1cmux-link-{stamp}"
    hits = j.sim.ocr_find(needle, timeout=20)
    check(hits, f"the URL never showed on the phone: {ocr_text(j)[:300]}")
    x, y, w, h, text = hits[-1]
    # The link part of the OCR line: aim at the path, past "docs: ".
    tap_x = x + w * 0.6
    pq.shot(f"link-{label}-before-tap")
    # A long press on the link first (after: Open Link / Open in Safari / Copy in the edit menu).
    j.sim.long_press(tap_x, y + h / 2, 1.0)
    time.sleep(1.2)
    pq.shot(f"link-{label}-long-press")
    menu = [e.label for e in j.sim.find(kind="MenuItem")] + [e.label for e in j.sim.find(kind="Button") if e.label in ("Open Link", "Open in Safari", "Copy")]
    # A tap on empty rows ends the selection (as iOS text does; never the menu), then the
    # tap on the link.
    j.sim.tap(200, 500)
    time.sleep(1.0)
    tabs_before = len(t.ws_tabs(t.mac_workspace(name=name)))
    tapped = j.sim.tap(tap_x, y + h / 2)

    def browser_tab():
        ws = t.mac_workspace(name=name)
        tabs = t.ws_tabs(ws)
        hit = [tab for _, tab in tabs if tab.get("kind") == "browser" and needle in (tab.get("url") or "")]
        return hit[0] if hit else None

    if label == "before":
        time.sleep(8)
        pq.shot(f"link-{label}-after-tap")
        tabs_after = len(t.ws_tabs(t.mac_workspace(name=name)))
        check(browser_tab() is None, "a browser tab opened on the base app")
        return {"menu": menu, "tabs_before": tabs_before, "tabs_after": tabs_after, "opened": False}
    tab, took = t.until(browser_tab, timeout=30, what="the Mac's browser tab at the link")
    listed = time.time() - tapped
    pane_of = {tab_["surface"]: pane for pane, tab_ in t.ws_tabs(t.mac_workspace(name=name))}
    time.sleep(4)
    pq.shot(f"link-{label}-after-tap")
    return {"menu": menu, "mac_listed_s": round(listed, 1), "url": tab.get("url"),
            "same_pane_as_terminal": pane_of.get(tab["surface"]) == pane_of.get(surface),
            "tabs_before": tabs_before, "tabs_after": len(pane_of)}


def find(j, label):
    """Page menu > Find…, "needle": three matches up in the scrollback, 3 of 3 then 2 of 3 and
    1 of 3 with Previous. Before: the page menu has no Find…."""
    name, surface = seed("find")
    # The command line spells ${n}dle: only the output says "needle-<row>".
    type_on_mac(surface, 'n=nee; for i in $(seq 1 240); do echo "row $i"; [ $((i%60)) = 0 ] && echo "${n}dle-$i"; done')
    open_terminal(j, name)
    j.sim.ocr_find("row 240", timeout=20)
    bottom = [e for e in j.sim.find(kind="Button") if e.frame[1] > 740 and e.frame[2] > 120]
    check(bottom, "no title capsule at the bottom")
    j.sim.tap_el(bottom[0])
    time.sleep(1.2)
    pq.shot(f"find-{label}-page-menu")
    items = [e.label for e in j.sim.find(kind="Button") if e.label]
    row = j.sim.find(label="Find…", kind="Button")
    if label == "before":
        check(not row, "the base app has Find…")
        j.sim.tap(200, 500)
        return {"page_menu": items, "find": False}
    check(row, f"no Find… in the page menu: {items[:24]}")
    j.sim.tap_el(row[0])
    time.sleep(1.2)
    pq.type_text("needle")
    time.sleep(2.0)
    pq.shot(f"find-{label}-first")
    counts = [ocr_text(j)]
    steps = []
    for direction in ("Previous", "Previous", "Previous"):
        b = [e for e in j.sim.find(kind="Button") if direction.lower() in (e.label or "").lower()]
        check(b, f"no {direction} button in the find bar: {[e.label for e in j.sim.find(kind='Button')][:20]}")
        j.sim.tap_el(b[0])
        time.sleep(1.5)
        steps.append(ocr_text(j))
        pq.shot(f"find-{label}-step{len(steps)}")
    done = [e for e in j.sim.find(kind="Button") if (e.label or "") in ("Done", "Close")]
    if done:
        j.sim.tap_el(done[0])
        time.sleep(1.0)
    pq.shot(f"find-{label}-done")
    import re
    seen = [re.findall(r"\b(\d) of (\d)\b", text) for text in counts + steps]
    return {"counts": seen, "rows_with_needle": [re.findall(r"needle-\d+", text) for text in counts + steps]}


def clear(j, label):
    """Page menu > Clear on a terminal with 300 rows of output: after, the Mac's scrollback
    is empty (`read-scrollback` total 0) and the phone shows the prompt only; before, the
    shell gets Ctrl-L and the Mac keeps every row."""
    name, surface = seed("clear")
    type_on_mac(surface, "seq 1 300")
    open_terminal(j, name)
    j.sim.ocr_find("300", timeout=20)
    rows_before = history_rows(surface)
    check(rows_before > 200, f"the Mac kept only {rows_before} rows")
    pq.shot(f"clear-{label}-before")
    t.page_menu(j, "Clear")
    if label == "before":
        time.sleep(5)
        rows_after = history_rows(surface)
        pq.shot(f"clear-{label}-after")
        j.sim.swipe(200, 300, 200, 700, 0.3)
        time.sleep(1.5)
        pq.shot(f"clear-{label}-scrolled-up")
        return {"mac_history_before": rows_before, "mac_history_after": rows_after,
                "phone_old_rows_scrolled_up": sorted({o[4].strip() for o in j.sim.ocr() if o[4].strip().isdigit()})[:10]}
    (rows_after, ), took = t.until(lambda: (lambda n: (n, ) if n == 0 else None)(history_rows(surface)), timeout=20,
                                    what="the Mac's scrollback to clear")
    time.sleep(2.5)
    pq.shot(f"clear-{label}-after")
    old_rows = lambda: sorted({o[4].strip() for o in j.sim.ocr() if o[4].strip().isdigit()})
    shown_after = old_rows()
    # Scrolling up on the phone finds nothing of the old output either.
    j.sim.swipe(200, 300, 200, 700, 0.3)
    time.sleep(1.5)
    pq.shot(f"clear-{label}-scrolled-up")
    return {"mac_history_before": rows_before, "mac_history_after": rows_after, "cleared_s": round(took, 1),
            "phone_old_rows_after": shown_after[:10], "phone_old_rows_scrolled_up": old_rows()[:10]}


FLOWS = {"link": link, "find": find, "clear": clear}


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
