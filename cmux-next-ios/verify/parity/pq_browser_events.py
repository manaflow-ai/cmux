"""The page's own asks over the real link (PROTOCOL.md `browser`, "Page asks"): links that open a
new tab or window, the long-press page menu, `<select>`, JavaScript dialogs and the page menu's
Hard Reload / Open in Safari.

The iOS app in ONE headless simulator and the real tagged cmux-next Mac app, hidden, both on
the rig mini (PQ_HOST=local runs this file there). A small http page is served on the mini
(the Mac's browser host loads it at http://127.0.0.1:PORT). Each flow is recorded to
PQ_RAW/<name>.mp4 and leaves stills in artifacts/shots.

    PQ_HOST=local PQ_RBASE=~/cmux-next-ios-e2e/brevents PQ_TAG=<rig tag> PQ_SIM=brevents-phone \\
    PQ_STATE=~/cmux-next-ios-e2e/brevents/state.json PQ_RAW=~/cmux-next-ios-e2e/brevents/raw \\
    python3 -c 'import pq_browser_events as b; b.run_all()'

`BE_MODE=before` runs the same steps against a base build and records what it does instead
(nothing opens, no menu, the dialog never shows); its flows never fail, they report.
"""
import os
import shlex
import subprocess
import time

import pq
import pq_tabs as t
from journey import check

STAMP = time.strftime("%H%M%S")
PORT = int(os.environ.get("BE_PORT", "8731"))
BEFORE = os.environ.get("BE_MODE") == "before"
SITE = f"{pq.RBASE}/site"
# The iframe's origin differs from the page's (localhost vs 127.0.0.1), so Chromium runs it in
# its own renderer and the page can navigate away while the iframe's alert is open.
PAGE = f"""<!doctype html><title>Events</title><meta name=viewport content="width=device-width">
<body style='font:22px -apple-system;padding:10px;margin:0;line-height:1.25'>
<p id=out style='font-weight:700'>EVTPAGE ready</p>
<p><a href="/next.html?blank" target=_blank style='font-size:26px'>BLANKLINK new tab</a></p>
<p><button onclick="window.open('/next.html?wopen')" style='font:22px -apple-system'>WOPEN window</button></p>
<p><button onclick="alert('ALERTMSG from the page')" style='font:22px -apple-system'>ALERTBTN</button>
<button onclick="out.textContent='CONFIRM '+confirm('Keep going?')" style='font:22px -apple-system'>CONFIRMBTN</button></p>
<p><button onclick="out.textContent='PROMPT '+prompt('Your name?','Ada')" style='font:22px -apple-system'>PROMPTBTN</button></p>
<p><select onchange="out.textContent='PICKED '+this.value" style='font:22px -apple-system'>
<option>Apple</option><option selected>Banana</option><option>Cherry</option><option>Damson</option></select></p>
<p><a href="/next.html?menu" style='font-size:26px'>MENULINK hold me</a></p>
<p><a href="/gone.html" style='font-size:22px'>GONEPAGE</a></p>
</body>"""
NEXT = """<!doctype html><title>Next</title><meta name=viewport content="width=device-width">
<body style='font:28px -apple-system;padding:12px'><h1>NEXTPAGE</h1><p id=q></p>
<script>document.getElementById('q').textContent='FROM '+location.search.slice(1)</script></body>"""
GONE = f"""<!doctype html><title>Gone</title><meta name=viewport content="width=device-width">
<body style='font:24px -apple-system;padding:12px'><p>GONEHOST waiting</p>
<iframe src="http://localhost:{PORT}/frame.html" style='width:90%;height:80px'></iframe>
<script>setTimeout(()=>{{location.href='/next.html?navigated'}},6000)</script></body>"""
FRAME = "<!doctype html><body>frame<script>setTimeout(()=>alert('FRAMEALERT closes by itself'),300)</script></body>"


def serve():
    """The test site on the mini (idempotent): an http server on PORT in SITE."""
    files = {"index.html": PAGE, "next.html": NEXT, "gone.html": GONE, "frame.html": FRAME}
    cmd = f"mkdir -p {SITE} && cd {SITE}"
    for name, body in files.items():
        cmd += f" && printf %s {shlex.quote(body)} > {name}"
    cmd += (f" && (curl -fsS -o /dev/null http://127.0.0.1:{PORT}/index.html || "
            f"(nohup python3 -m http.server {PORT} --bind 127.0.0.1 </dev/null >/dev/null 2>&1 &))")
    r = pq.rsh(cmd)
    check(r.returncode == 0, f"site: {r.stderr.strip()[:200]}")
    t0 = time.time()
    while time.time() - t0 < 30:
        if pq.rsh(f"curl -fsS -o /dev/null http://127.0.0.1:{PORT}/index.html").returncode == 0:
            return f"http://127.0.0.1:{PORT}"
        time.sleep(0.5)
    check(False, "the test site did not start")


def ocr_wait(j, needle, timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if j.sim.ocr_find(needle):
            return time.time() - t0
        time.sleep(0.7)
    return None


def at(j, needle, timeout=20):
    """The center (points) of the first OCR hit for `needle`."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        hits = j.sim.ocr_find(needle)
        if hits:
            x, y, w, h, _ = hits[0]
            return x + w / 2, y + h / 2
        time.sleep(0.7)
    check(False, f"{needle!r} is not on screen")


def open_page(j, path="index.html"):
    """A workspace whose browser tab (opened on the Mac) shows the test site."""
    base = serve()
    a = t.seed(f"bev-{STAMP}-{path.split('.')[0]}", terminals=1)
    pane = t.ws_tabs(a)[0][0]
    t.mac_raw({"cmd": "new-browser-tab", "url": f"{base}/{path}", "pane": pane})
    t.open_ws(j, a["name"])
    took = ocr_wait(j, "EVTPAGE" if path == "index.html" else "GONEHOST", timeout=60)
    if took is None:
        # A page that opened hidden waits for the phone to show it again: the grid and back.
        t.open_tab(j, "Events")
        took = ocr_wait(j, "EVTPAGE", timeout=30)
    check(took is not None, f"{path} never showed on the phone")
    return a


def browser_tabs(ws_name):
    ws = t.mac_workspace(name=ws_name)
    return [tab for _, tab in t.ws_tabs(ws) if tab.get("kind") == "browser" or "url" in tab]


def tab_count(ws_name):
    return len(t.ws_tabs(t.mac_workspace(name=ws_name)))


def result(j, ok, what, before_note):
    """After: the check. Before: what the base did, reported, never a failure."""
    if BEFORE:
        return before_note
    check(ok, what)
    return what


# ---------------------------------------------------------------- flows

@t.flow("open-tab")
def open_tab(j):
    """target=_blank and window.open: a new browser tab on the Mac, shown on the phone."""
    a = open_page(j)
    name = a["name"]
    out = []
    before = tab_count(name)
    j.sim.tap(*at(j, "BLANKLINK"))
    time.sleep(1.0)
    j.sim.shot(f"open-tab-blank-{'before' if BEFORE else 'after'}")
    shown = ocr_wait(j, "FROM blank", timeout=25)
    j.sim.shot(f"open-tab-blank-shown-{'before' if BEFORE else 'after'}")
    count = tab_count(name)
    out.append(result(j, shown is not None and count == before + 1,
                      f"target=_blank: a new tab on the Mac ({before} -> {count}), shown on the phone in {shown or 0:.1f} s",
                      f"target=_blank: Mac tabs {before} -> {count}; phone shows the new page: {shown is not None}"))
    # Back to the page, then window.open.
    t.open_tab(j, "Events")
    check(ocr_wait(j, "EVTPAGE", timeout=20) is not None, "the events page did not come back")
    before = tab_count(name)
    j.sim.tap(*at(j, "WOPEN"))
    shown = ocr_wait(j, "FROM wopen", timeout=25)
    j.sim.shot(f"open-tab-wopen-{'before' if BEFORE else 'after'}")
    count = tab_count(name)
    out.append(result(j, shown is not None and count == before + 1,
                      f"window.open: a new tab ({before} -> {count}), shown in {shown or 0:.1f} s",
                      f"window.open: Mac tabs {before} -> {count}; phone shows it: {shown is not None}"))
    return "; ".join(out)


@t.flow("context-menu")
def context_menu(j):
    """Long press on a link: the page's own menu; Open Link in New Tab opens it on the Mac."""
    a = open_page(j)
    name = a["name"]
    x, y = at(j, "MENULINK")
    before = tab_count(name)
    j.sim.long_press(x, y, 1.2)
    row = j.sim.wait(label="Open Link in New Tab", timeout=8)
    j.sim.shot(f"context-menu-{'before' if BEFORE else 'after'}")
    rows = [e.label for e in j.sim.find(kind="Button") if e.label][:16]
    if BEFORE:
        return f"long press on a link: no menu (buttons on screen: {rows})"
    check(row, f"no page menu after a long press; buttons: {rows}")
    labels = [e.label for e in j.sim.tree() if e.label]
    check("Copy Link Address" not in labels and "Inspect" not in labels, "a Mac-only row is in the phone's menu")
    j.sim.tap_el(row)
    _, took = t.until(lambda: tab_count(name) == before + 1, timeout=20, what="the Mac to open the link's tab")
    time.sleep(2)
    j.sim.shot("context-menu-opened")
    toast = j.sim.ocr_find("Opened in a new tab") or j.sim.ocr_find("NEXTPAGE")
    return (f"long press showed the page's menu ({', '.join(x for x in labels if x.startswith('Open'))}); "
            f"Open Link in New Tab opened a tab on the Mac in {took:.1f} s ({'toast' if toast else 'no toast seen'})")


@t.flow("dialogs")
def dialogs(j):
    """alert, confirm (Cancel), prompt (typed answer) as system alerts; the page gets each answer."""
    open_page(j)
    out = []
    j.sim.tap(*at(j, "ALERTBTN"))
    alert = j.sim.wait(label="OK", kind="Button", timeout=10)
    j.sim.shot(f"dialog-alert-{'before' if BEFORE else 'after'}")
    if BEFORE:
        stuck = j.sim.ocr_find("ALERTMSG")
        return f"alert: no alert on the phone (message on screen: {bool(stuck)}); the page waits for an answer that never comes"
    check(alert and j.sim.ocr_find("ALERTMSG"), "no alert with the page's message")
    j.sim.tap_el(alert)
    time.sleep(1)
    out.append("alert shown with its message, OK closed it")
    j.sim.tap(*at(j, "CONFIRMBTN"))
    cancel = j.sim.wait(label="Cancel", kind="Button", timeout=10)
    check(cancel, "no confirm alert")
    j.sim.shot("dialog-confirm")
    j.sim.tap_el(cancel)
    check(ocr_wait(j, "CONFIRM false", timeout=10) is not None, "the page did not get Cancel")
    out.append("confirm: Cancel -> page 'CONFIRM false'")
    j.sim.tap(*at(j, "PROMPTBTN"))
    field = j.sim.wait(ident="browser.dialog.field", timeout=10) or j.sim.wait(kind="TextField", timeout=3)
    check(field, "no prompt field")
    check(field.value == "Ada" or j.sim.ocr_find("Ada"), "the prompt's default text is missing")
    j.sim.tap_el(field)
    time.sleep(0.8)
    j.sim.dismiss_keyboard_intro()
    # Typed after the default text: the page gets exactly what the field holds.
    j.sim.softtype("Grace")
    j.sim.shot("dialog-prompt")
    ok = j.sim.wait(label="OK", kind="Button", timeout=5)
    j.sim.tap_el(ok)
    check(ocr_wait(j, "PROMPT AdaGrace", timeout=10) is not None, "the page did not get the typed answer")
    j.sim.shot("dialog-prompt-answered")
    out.append("prompt: default 'Ada' shown, typed 'Grace', OK -> page 'PROMPT AdaGrace'")
    return "; ".join(out)


@t.flow("dialog-dismissed")
def dialog_dismissed(j):
    """A dialog the page closes itself (it navigates away): the phone's alert goes, unanswered."""
    open_page(j)
    j.sim.tap(*at(j, "GONEPAGE"))
    alert = j.sim.wait(label="OK", kind="Button", timeout=15)
    j.sim.shot(f"dialog-dismissed-shown-{'before' if BEFORE else 'after'}")
    if BEFORE:
        return f"iframe alert: shown on the phone: {bool(alert)}"
    check(alert, "the iframe's alert never showed")
    gone = None
    t0 = time.time()
    while time.time() - t0 < 15:
        if not j.sim.find(label="OK", kind="Button"):
            gone = time.time() - t0
            break
        time.sleep(0.5)
    check(gone is not None, "the alert stayed after the page navigated away")
    check(ocr_wait(j, "FROM navigated", timeout=15) is not None, "the page did not navigate")
    j.sim.shot("dialog-dismissed-gone")
    return f"the page navigated while its iframe's alert was open: the alert closed by itself {gone:.1f} s later, no answer sent"


@t.flow("select")
def select(j):
    """A <select>: its options in a sheet; a pick reaches the page."""
    open_page(j)
    j.sim.tap(*at(j, "Banana"))
    sheet = j.sim.wait(ident="browser.select.option.3", timeout=10) or j.sim.wait(label="Damson", timeout=2)
    j.sim.shot(f"select-{'before' if BEFORE else 'after'}")
    if BEFORE:
        return f"select: options on the phone: {bool(sheet)}"
    check(sheet, "no options sheet for the select")
    j.sim.tap_el(sheet)
    took = ocr_wait(j, "PICKED Damson", timeout=10)
    j.sim.shot("select-picked")
    check(took is not None, "the page did not get the pick")
    return f"select: the options sheet listed Apple..Damson; picking Damson reached the page in {took:.1f} s"


@t.flow("page-menu")
def page_menu(j):
    """Page menu: Hard Reload reloads the page; Open in Safari is offered for the web address."""
    open_page(j)
    j.sim.tap(*at(j, "PROMPTBTN"))
    ok = j.sim.wait(label="OK", kind="Button", timeout=10)
    if ok:
        j.sim.tap_el(ok)  # the page now reads "PROMPT Ada": a reload brings back "EVTPAGE ready"
    check(ocr_wait(j, "PROMPT", timeout=10) is not None or BEFORE, "the page did not change before the reload")
    menu = j.sim.wait(label="Page Menu", kind="Button", timeout=5)
    check(menu, "no Page Menu button")
    j.sim.tap_el(menu)
    time.sleep(1.0)
    labels = [e.label for e in j.sim.find(kind="Button") if e.label]
    j.sim.shot(f"page-menu-{'before' if BEFORE else 'after'}")
    if BEFORE:
        return f"page menu rows: {labels[:12]}"
    check("Hard Reload" in labels and "Open in Safari" in labels, f"page menu rows: {labels}")
    row = j.sim.wait(label="Hard Reload", kind="Button", timeout=3)
    j.sim.tap_el(row)
    took = ocr_wait(j, "EVTPAGE ready", timeout=15)
    j.sim.shot("page-menu-hard-reloaded")
    check(took is not None, "Hard Reload did not reload the page")
    menu = j.sim.wait(label="Page Menu", kind="Button", timeout=5)
    j.sim.tap_el(menu)
    time.sleep(1.0)
    row = j.sim.wait(label="Open in Safari", kind="Button", timeout=5)
    check(row, "no Open in Safari row")
    j.sim.tap_el(row)
    safari = ocr_wait(j, "EVTPAGE", timeout=25)
    j.sim.shot("page-menu-open-in-safari")
    tree = " ".join(e.label or "" for e in j.sim.tree()[:3])
    check(safari is not None, "Safari did not show the page")
    j.sim.launch(pq.BUNDLE, terminate=False)  # back to cmux
    time.sleep(2)
    return (f"page menu has Hard Reload and Open in Safari; Hard Reload reloaded the page in {took:.1f} s; "
            f"Open in Safari opened the page's address in Safari ({tree[:60]!r})")


# dialog-dismissed is not in the default run: while a frame's alert is open the page's own
# renderer is blocked, so nothing on the page can close it over the real link (the host's
# rb.dialog.cancel path is covered by PageEventsTests.aDialogThePageClosedGoesUnanswered).
ORDER = ["open-tab", "context-menu", "select", "dialogs", "page-menu"]


def run(name):
    t0 = time.time()
    try:
        notes = t.FLOWS[name]()
        print(f"PASS {name} ({time.time() - t0:.0f} s): {notes}", flush=True)
        return True
    except Exception as error:  # noqa: BLE001 - a flow's failure is its result
        print(f"FAIL {name} ({time.time() - t0:.0f} s): {error}", flush=True)
        return False


def run_all(names=None):
    return all([run(name) for name in (names or ORDER)])


def stop_site():
    pq.rsh(f"pkill -f 'http.server {PORT}' || true")


if __name__ == "__main__":
    import sys
    ok = run_all(sys.argv[1:] or None)
    subprocess.run(["true"])
    sys.exit(0 if ok else 1)
