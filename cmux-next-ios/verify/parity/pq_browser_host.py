"""The Mac browser host's page asks over the real link (PROTOCOL.md `browser`, "Page asks"): the
long-press menu's Open Link in New Tab and View Page Source (`rb.open_tab` from Chromium's
OpenURLFromTab and the host's view-source tab), a dialog whose frame the page removes
(`rb.dialog.cancel`), and Find… in the page menu (`rb.find`, `rb.find.result`).

The iOS app in ONE headless simulator and the real tagged cmux-next Mac app, hidden, both on the
rig mini (PQ_HOST=local runs this file there), with the test site of pq_browser_events.py plus
the pages below. Each flow is recorded to PQ_RAW/<name>.mp4 and leaves stills in artifacts/shots.

    PQ_HOST=local PQ_RBASE=~/cmux-next-ios-e2e/bhost PQ_TAG=<rig tag> PQ_SIM=bhost-phone \\
    PQ_STATE=~/cmux-next-ios-e2e/bhost/state.json PQ_RAW=~/cmux-next-ios-e2e/bhost/raw \\
    python3 pq_browser_host.py [flow...]

`BE_MODE=before` runs the same steps against the base (its app and its browser host) and reports
what it does instead (no tab-opening rows, the alert stays, no Find…); its flows never fail.
"""
import os
import re
import shlex
import time

import pq
import pq_browser_events as b
import pq_tabs as t
from journey import check

BEFORE = b.BEFORE
LABEL = "before" if BEFORE else "after"
# Seconds after load the page removes its iframe (whose alert is up by then).
REMOVE_AFTER = int(os.environ.get("BH_REMOVE_AFTER", "15"))
# The iframe's origin differs from the page's (localhost vs 127.0.0.1): Chromium runs it in its own
# renderer, so the page's script keeps running (and removes it) while the iframe's alert is open.
FRAMEHOST = f"""<!doctype html><title>Frames</title><meta name=viewport content="width=device-width">
<body style='font:24px -apple-system;padding:12px'><p id=st style='font-weight:700'>FRAMEHOST waiting</p>
<iframe id=f src="http://localhost:{b.PORT}/frame2.html" style='width:90%;height:120px'></iframe>
<script>setTimeout(()=>{{f.remove();st.textContent='FRAME REMOVED'}},{REMOVE_AFTER * 1000})</script></body>"""
FRAME2 = """<!doctype html><body style='font:20px -apple-system'>FRAMEDOC
<script>setTimeout(()=>alert('FRAMEALERT from the frame'),500)</script></body>"""
FINDPAGE = """<!doctype html><title>Find</title><meta name=viewport content="width=device-width">
<body style='font:22px -apple-system;padding:12px;line-height:1.4'><h2>FINDPAGE</h2>
<p>alpha QUOKKA beta</p><p>gamma delta</p><p>epsilon QUOKKA zeta</p><p>eta theta</p>
<p>iota kappa QUOKKA lambda</p></body>"""


def serve():
    base = b.serve()
    files = {"framehost.html": FRAMEHOST, "frame2.html": FRAME2, "find.html": FINDPAGE}
    cmd = f"cd {b.SITE}"
    for name, body in files.items():
        cmd += f" && printf %s {shlex.quote(body)} > {name}"
    r = pq.rsh(cmd)
    check(r.returncode == 0, f"site: {r.stderr.strip()[:200]}")
    return base


def open_page(j, path, needle):
    """A workspace whose browser tab (opened on the Mac) shows `path` of the test site."""
    base = serve()
    b.app_front(j)
    a = t.seed(f"bh-{b.STAMP}-{path.split('.')[0]}", terminals=1)
    pane = t.ws_tabs(a)[0][0]
    t.mac_raw({"cmd": "new-browser-tab", "url": f"{base}/{path}", "pane": pane})
    t.open_ws(j, a["name"])
    took = b.ocr_wait(j, needle, timeout=60)
    if took is None:
        b.open_card(j) if path == "index.html" else open_card_by_host(j)
        took = b.ocr_wait(j, needle, timeout=60)
    check(took is not None, f"{path} never showed on the phone")
    return a


def open_card_by_host(j):
    pq.open_grid(j)
    e = j.sim.wait(prefix="127.0.0.1, tab", kind="Button", timeout=10) or \
        next(iter([x for x in j.sim.find(suffix=", tab") if "Terminal" not in (x.label or "")]), None)
    check(e, f"no page card; cards: {[x.label for x in j.sim.find(suffix=', tab')]}")
    j.sim.tap_el(e)
    time.sleep(1.5)


def menu_rows():
    return [e.label for e in pq.ctx()[0].find(kind="Button") if e.label]


def long_press_menu(j, x, y, want):
    """Long press at (x, y); the page's menu, waiting for row `want` (or the empty menu)."""
    j.sim.long_press(x, y, 1.2)
    t0 = time.time()
    while time.time() - t0 < 40:
        if j.sim.find(label=want, kind="Button") or j.sim.find(label="No actions for this spot"):
            break
        time.sleep(0.5)
    return j.sim.find(label=want, kind="Button")


def mac_browser_urls(ws_name):
    return [tab.get("url") or "" for _, tab in t.ws_tabs(t.mac_workspace(name=ws_name))]


# ---------------------------------------------------------------- flows

@t.flow("menu-new-tab")
def menu_new_tab(j):
    """Long press on a link > Open Link in New Tab: a new browser tab on the Mac (Chromium's
    OpenURLFromTab, forwarded as rb.open_tab), shown on the phone."""
    a = open_page(j, "index.html", "EVTPAGE")
    name = a["name"]
    before = b.tab_count(name)
    x, y = b.at(j, "MENULINK")
    row = long_press_menu(j, x, y, "Open Link in New Tab")
    rows = menu_rows()[:20]
    j.sim.shot(f"menu-new-tab-menu-{LABEL}")
    if BEFORE:
        return f"long press on a link: Open Link in New Tab offered: {bool(row)}; rows: {rows}"
    check(row, f"no Open Link in New Tab in the link's menu: {rows}")
    j.sim.tap_el(row[0])
    (count, ), took = t.until(lambda: (lambda n: (n, ) if n == before + 1 else None)(b.tab_count(name)),
                              timeout=60, what="the Mac's new tab")
    shown = b.ocr_wait(j, "FROM menu", timeout=60)
    j.sim.shot(f"menu-new-tab-opened-{LABEL}")
    if shown is None:
        # Opened in the background (Chromium's Open Link in New Tab is a background tab): the grid has it.
        pq.open_grid(j)
        j.sim.shot("menu-new-tab-grid")
        card = j.sim.wait(prefix="Next, tab", kind="Button", timeout=20)
        check(card, f"the new tab is not in the phone's grid: {[x.label for x in j.sim.find(suffix=', tab')]}")
        j.sim.tap_el(card)
        shown = b.ocr_wait(j, "FROM menu", timeout=60)
        j.sim.shot("menu-new-tab-shown")
    check(shown is not None, "the phone never showed the new tab's page")
    urls = mac_browser_urls(name)
    check(any("next.html?menu" in u for u in urls), f"the Mac's tabs: {urls}")
    return (f"Open Link in New Tab: Mac tabs {before} -> {count} in {took:.1f} s "
            f"(the new tab is {[u for u in urls if 'menu' in u][0]}); the phone shows NEXTPAGE FROM menu")


@t.flow("view-source")
def view_source(j):
    """Long press on the page > View Page Source: a view-source: tab beside the page on the Mac,
    shown on the phone with the page's HTML."""
    a = open_page(j, "index.html", "EVTPAGE")
    name = a["name"]
    before = b.tab_count(name)
    gx, gy = b.at(j, "GONEPAGE")
    row = long_press_menu(j, gx, gy + 200, "View Page Source")
    rows = menu_rows()[:20]
    j.sim.shot(f"view-source-menu-{LABEL}")
    if BEFORE:
        return f"long press on the page: View Page Source offered: {bool(row)}; rows: {rows}"
    check(row, f"no View Page Source in the page's menu: {rows}")
    j.sim.tap_el(row[0])
    (count, ), took = t.until(lambda: (lambda n: (n, ) if n == before + 1 else None)(b.tab_count(name)),
                              timeout=60, what="the Mac's view-source tab")
    shown = b.ocr_wait(j, "doctype", timeout=60)
    j.sim.shot(f"view-source-opened-{LABEL}")
    check(shown is not None, "the phone never showed the page's source")
    urls = mac_browser_urls(name)
    src = [u for u in urls if u.startswith("view-source:")]
    check(src, f"no view-source: tab on the Mac: {urls}")
    return f"View Page Source: Mac tabs {before} -> {count} in {took:.1f} s ({src[0]}); the phone shows the HTML"


@t.flow("frame-dialog")
def frame_dialog(j):
    """An iframe's alert that the page takes away (it removes the iframe): the phone's alert
    closes by itself, unanswered (the host's rb.dialog.cancel, from Chromium's frame detach)."""
    open_page(j, "framehost.html", "FRAMEHOST")
    alert = j.sim.wait(label="OK", kind="Button", timeout=REMOVE_AFTER + 30)
    shown = time.time()
    j.sim.shot(f"frame-dialog-shown-{LABEL}")
    check(alert and j.sim.ocr_find("FRAMEALERT"), "the frame's alert never showed")
    gone = None
    misses = 0
    while time.time() - shown < REMOVE_AFTER + 75:
        # Three reads in a row without the alert: one empty accessibility read is not "gone".
        misses = misses + 1 if not j.sim.find(label="OK", kind="Button") else 0
        if misses == 3:
            gone = time.time() - shown
            break
        time.sleep(0.5)
    j.sim.shot(f"frame-dialog-gone-{LABEL}")
    if BEFORE:
        stays = gone is None
        if alert and stays:
            j.sim.tap_el(j.sim.find(label="OK", kind="Button")[0])
        return (f"the page removed the iframe {REMOVE_AFTER} s after load; the phone's alert "
                f"{'stayed up' if stays else f'closed after {gone:.1f} s'} for {REMOVE_AFTER + 75} s")
    check(gone is not None, "the alert stayed: no rb.dialog.cancel came")
    removed = b.ocr_wait(j, "FRAME REMOVED", timeout=30)
    j.sim.shot("frame-dialog-removed")
    check(removed is not None, "the page did not show FRAME REMOVED")
    return (f"the frame's alert showed, then the page removed the iframe: the phone's alert closed by itself "
            f"{gone:.1f} s after it showed, unanswered (OK never tapped), and the page reads FRAME REMOVED")


def find_counts():
    """'N of M' read from the find bar (accessibility first, else OCR)."""
    sim = pq.ctx()[0]
    labels = " ".join(f"{e.label or ''} {e.value or ''}" for e in sim.tree())
    hits = re.findall(r"\b(\d+) of (\d+)\b", labels)
    if not hits:
        hits = re.findall(r"\b(\d+) of (\d+)\b", " ".join(o[4] for o in sim.ocr()))
    return hits[-1] if hits else None


@t.flow("find")
def find(j):
    """Page menu > Find…, QUOKKA: the Mac's browser finds three matches; the bar reads 1 of 3,
    Next steps to 2 of 3 and 3 of 3, Previous back to 2 of 3; Done ends the search."""
    open_page(j, "find.html", "FINDPAGE")
    menu = j.sim.wait(label="Page Menu", kind="Button", timeout=10)
    check(menu, "no Page Menu button")
    j.sim.tap_el(menu)
    time.sleep(1.2)
    rows = menu_rows()[:24]
    j.sim.shot(f"find-page-menu-{LABEL}")
    row = j.sim.find(label="Find…", kind="Button")
    if BEFORE:
        j.sim.tap(200, 450)
        return f"page menu: Find… offered: {bool(row)}; rows: {rows}"
    check(row, f"no Find… in the page menu: {rows}")
    j.sim.tap_el(row[0])
    time.sleep(1.5)
    pq.type_text("QUOKKA")
    counts = []
    first, took = t.until(lambda: find_counts(), timeout=45, what="the find bar's count")
    j.sim.shot("find-first")
    counts.append(first)
    check(first == ("1", "3"), f"the first count is {first}, not 1 of 3")
    for direction, want in (("next", ("2", "3")), ("next", ("3", "3")), ("previous", ("2", "3"))):
        button = [e for e in j.sim.find(kind="Button") if direction in (e.label or "").lower()]
        check(button, f"no {direction} button in the find bar: {[e.label for e in j.sim.find(kind='Button')][:20]}")
        j.sim.tap_el(button[0])
        got, _ = t.until(lambda: (lambda c: c if c == want else None)(find_counts()), timeout=30,
                         what=f"{want[0]} of {want[1]} after {direction}")
        counts.append(got)
        j.sim.shot(f"find-{direction}-{want[0]}")
    done = [e for e in j.sim.find(kind="Button") if (e.label or "") in ("Done", "Close")]
    check(done, "no Done in the find bar")
    j.sim.tap_el(done[0])
    time.sleep(1.5)
    j.sim.shot("find-done")
    check(find_counts() is None, "the count is still shown after Done")
    return (f"Find…: QUOKKA -> {first[0]} of {first[1]} in {took:.1f} s; Next, Next, Previous -> "
            f"{', '.join(f'{c[0]} of {c[1]}' for c in counts[1:])}; Done closed the bar")


# view-source stays runnable by name: on the phone the row is left out (a phone may not open a
# view-source: tab, cmux-mobile-host policy.rs), so it is not in the default order.
ORDER = ["menu-new-tab", "frame-dialog", "find"]


if __name__ == "__main__":
    import sys
    b.ORDER = ORDER
    names = sys.argv[1:] or ORDER
    ok = all([b.run(name) for name in names])
    sys.exit(0 if ok else 1)
