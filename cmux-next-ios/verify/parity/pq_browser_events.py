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
import json
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
# The page starts a navigation to another site that answers slowly (SLOW_PORT holds the
# response SLOW_SECONDS), then shows an alert: the alert is up when the navigation commits,
# and Chromium closes the page's dialogs on commit (the host sends rb.dialog.cancel).
SLOW_PORT = PORT + 1
SLOW_SECONDS = int(os.environ.get("BE_SLOW_SECONDS", "40"))
GONE = f"""<!doctype html><title>Gone</title><meta name=viewport content="width=device-width">
<body style='font:24px -apple-system;padding:12px'><p>GONEHOST waiting</p>
<script>setTimeout(()=>{{location.href='http://localhost:{SLOW_PORT}/next.html?navigated';
alert('NAVALERT closes by itself')}},1500)</script></body>"""
SLOW = f"""import http.server, time
NEXT = {NEXT!r}.encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep({SLOW_SECONDS})
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(NEXT)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", {SLOW_PORT}), H).serve_forever()
"""
FRAME = "<!doctype html><body>frame<script>setTimeout(()=>alert('FRAMEALERT closes by itself'),300)</script></body>"


def serve():
    """The test site on the mini (idempotent): an http server on PORT in SITE."""
    files = {"index.html": PAGE, "next.html": NEXT, "gone.html": GONE, "frame.html": FRAME, "slow.py": SLOW}
    cmd = f"mkdir -p {SITE} && cd {SITE}"
    for name, body in files.items():
        cmd += f" && printf %s {shlex.quote(body)} > {name}"
    cmd += (f" && (curl -fsS -o /dev/null http://127.0.0.1:{PORT}/index.html || "
            f"(nohup python3 -m http.server {PORT} --bind 127.0.0.1 </dev/null >/dev/null 2>&1 & echo $! > http-{PORT}.pid))"
            f" && (nc -z 127.0.0.1 {SLOW_PORT} || (nohup python3 slow.py </dev/null >/dev/null 2>&1 & echo $! > slow-{SLOW_PORT}.pid))")
    r = pq.rsh(cmd)
    check(r.returncode == 0, f"site: {r.stderr.strip()[:200]}")
    t0 = time.time()
    while time.time() - t0 < 60:
        if pq.rsh(f"curl -fsS -o /dev/null http://127.0.0.1:{PORT}/index.html && nc -z 127.0.0.1 {SLOW_PORT}").returncode == 0:
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


def app_front(j):
    """cmux in front with nothing over it: the page-menu flow leaves Safari in front, a fresh
    boot shows the keyboard intro, and an earlier flow can leave its page's alert open. The
    app is not restarted: a restart that reconnects to a live page crashes the base app's
    video decoder (BrowserVideoDecoder.decode, outside this change)."""
    j.sim.launch(pq.BUNDLE, terminate=False)
    time.sleep(3)
    stale = j.sim.find(label="OK", kind="Button")
    if stale:
        j.sim.tap_el(stale[0])
        time.sleep(1)
    j.sim.dismiss_keyboard_intro()
    # A workspace's tab grid: its back button (the grid's Done spans the bottom bar, and a tap
    # at its middle lands on the tab count).
    for _ in range(3):
        back = [e for e in j.sim.find(label="Workspaces", kind="Button") if e.frame[1] < 120]
        if not back:
            break
        j.sim.tap_el(back[0])
        time.sleep(1.5)


def open_card(j):
    """The events page's card: titled Events once it loaded (other pages are Next, Gone), else
    by its host."""
    pq.open_grid(j)
    e = j.sim.wait(prefix="Events, tab", kind="Button", timeout=15) or j.sim.wait(prefix="127.0.0.1, tab", kind="Button", timeout=5)
    check(e, f"no events card; cards: {[x.label for x in j.sim.find(suffix=', tab')]}")
    j.sim.tap_el(e)
    time.sleep(1.5)


def open_page(j, path="index.html"):
    """A workspace whose browser tab (opened on the Mac) shows the test site."""
    base = serve()
    app_front(j)
    a = t.seed(f"bev-{STAMP}-{path.split('.')[0]}", terminals=1)
    pane = t.ws_tabs(a)[0][0]
    t.mac_raw({"cmd": "new-browser-tab", "url": f"{base}/{path}", "pane": pane})
    t.open_ws(j, a["name"])
    took = ocr_wait(j, "EVTPAGE" if path == "index.html" else "GONEHOST", timeout=60)
    if took is None:
        # A page that opened hidden waits for the phone to show it again: the grid and back
        # (its card is titled with the page's host).
        open_card(j)
        took = ocr_wait(j, "EVTPAGE" if path == "index.html" else "GONEHOST", timeout=60)
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
    shown = ocr_wait(j, "FROM blank", timeout=60)
    j.sim.shot(f"open-tab-blank-shown-{'before' if BEFORE else 'after'}")
    count = tab_count(name)
    out.append(result(j, shown is not None and count == before + 1,
                      f"target=_blank: a new tab on the Mac ({before} -> {count}), shown on the phone in {shown or 0:.1f} s",
                      f"target=_blank: Mac tabs {before} -> {count}; phone shows the new page: {shown is not None}"))
    # Back to the page, then window.open.
    open_card(j)
    check(ocr_wait(j, "EVTPAGE", timeout=45) is not None, "the events page did not come back")
    before = tab_count(name)
    j.sim.tap(*at(j, "WOPEN"))
    shown = ocr_wait(j, "FROM wopen", timeout=60)
    j.sim.shot(f"open-tab-wopen-{'before' if BEFORE else 'after'}")
    count = tab_count(name)
    out.append(result(j, shown is not None and count == before + 1,
                      f"window.open: a new tab ({before} -> {count}), shown in {shown or 0:.1f} s",
                      f"window.open: Mac tabs {before} -> {count}; phone shows it: {shown is not None}"))
    return "; ".join(out)


def phone_menus(since):
    """The page menus the phone got since `since` (its log: `menu <token> context [id:type, ...]`)."""
    r = pq.rsh(f"xcrun simctl spawn {pq.load()['udid']} log show --style compact --start '{since}' "
               "--predicate 'subsystem == \"dev.cmux.mobile\" AND category == \"browser-stream\"' "
               "| grep ' context \\['", timeout=120)
    return r.stdout.strip().splitlines()


def reload_rows(j):
    return [e for e in j.sim.find(label="Reload", kind="Button")]


@t.flow("context-menu")
def context_menu(j):
    """Long press: the page's own menu with only rows that act on the page. On a link every
    Chromium row either acts on the Mac (Copy, Save, Print, Speech, Inspect) or opens a tab the
    host does not hand to viewers (Open Link in New Tab), so it says there are none. On the page
    itself, Reload reloads it."""
    a = open_page(j)
    name = a["name"]
    before = tab_count(name)
    since = pq.rsh("date '+%Y-%m-%d %H:%M:%S'").stdout.strip()
    x, y = at(j, "MENULINK")
    j.sim.long_press(x, y, 1.2)
    none = j.sim.wait(label="No actions for this spot", timeout=30)
    rows = [e.label for e in j.sim.find(kind="Button") if e.label][:16]
    j.sim.shot(f"context-menu-{'before' if BEFORE else 'after'}")
    if BEFORE:
        return f"long press on a link: no menu (buttons on screen: {rows})"
    labels = [e.label for e in j.sim.tree() if e.label]
    check(none, f"the link's menu is not the honest empty one; rows: {rows}")
    for dead in ("Open Link in New Tab", "Copy Link Address", "Inspect", "Speech", "Print…"):
        check(dead not in labels, f"{dead!r} is in the phone's menu")
    # The page did send its link menu (an empty one also shows when none comes).
    got = [line for line in phone_menus(since) if "50100:command" in line]
    check(got, "the phone got no link menu from the page")
    # Close it (a tap beside it), then change the page and long-press its empty area.
    gx, gy = at(j, "GONEPAGE")
    j.sim.tap(gx, gy + 260)
    t0 = time.time()
    while j.sim.find(label="No actions for this spot") and time.time() - t0 < 30:
        time.sleep(0.5)
    j.sim.tap(*at(j, "PROMPTBTN"))
    ok = j.sim.wait(label="OK", kind="Button", timeout=30)
    check(ok, "no prompt to change the page with")
    j.sim.tap_el(ok)
    check(ocr_wait(j, "PROMPT", timeout=45) is not None, "the page did not change before the reload")
    toolbar = {tuple(e.frame) for e in reload_rows(j)}  # the phone's own Reload button
    j.sim.long_press(gx, gy + 200, 1.2)
    row = None
    t0 = time.time()
    while row is None and time.time() - t0 < 30:
        row = next((e for e in reload_rows(j) if tuple(e.frame) not in toolbar), None)
        time.sleep(0.5)
    j.sim.shot("context-menu-page")
    page_rows = [e.label for e in j.sim.find(kind="Button") if e.label][:16]
    check(row, f"no Reload in the page's menu; buttons: {page_rows}")
    j.sim.tap_el(row)
    took = ocr_wait(j, "EVTPAGE ready", timeout=60)
    j.sim.shot("context-menu-reloaded")
    check(took is not None, "the page's Reload did not reload it")
    check(tab_count(name) == before, "the Mac's tab count changed")
    return (f"link: the page sent its menu ({got[-1].split(' context ')[-1][:90]}...) and the phone says "
            f"'No actions for this spot' (no Mac-only or tab-opening row); page: the menu's Reload reloaded it "
            f"in {took:.1f} s (Mac tabs {before} -> {tab_count(name)})")


@t.flow("dialogs")
def dialogs(j):
    """alert, confirm (Cancel), prompt (typed answer) as system alerts; the page gets each answer."""
    open_page(j)
    out = []
    j.sim.tap(*at(j, "ALERTBTN"))
    alert = j.sim.wait(label="OK", kind="Button", timeout=30)
    j.sim.shot(f"dialog-alert-{'before' if BEFORE else 'after'}")
    if BEFORE:
        stuck = j.sim.ocr_find("ALERTMSG")
        return f"alert: no alert on the phone (message on screen: {bool(stuck)}); the page waits for an answer that never comes"
    check(alert and j.sim.ocr_find("ALERTMSG"), "no alert with the page's message")
    j.sim.tap_el(alert)
    time.sleep(1)
    out.append("alert shown with its message, OK closed it")
    j.sim.tap(*at(j, "CONFIRMBTN"))
    cancel = j.sim.wait(label="Cancel", kind="Button", timeout=30)
    check(cancel, "no confirm alert")
    j.sim.shot("dialog-confirm")
    j.sim.tap_el(cancel)
    check(ocr_wait(j, "CONFIRM false", timeout=45) is not None, "the page did not get Cancel")
    out.append("confirm: Cancel -> page 'CONFIRM false'")
    j.sim.tap(*at(j, "PROMPTBTN"))
    field = j.sim.wait(ident="browser.dialog.field", timeout=30) or j.sim.wait(kind="TextField", timeout=3)
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
    check(ocr_wait(j, "PROMPT AdaGrace", timeout=45) is not None, "the page did not get the typed answer")
    j.sim.shot("dialog-prompt-answered")
    out.append("prompt: default 'Ada' shown, typed 'Grace', OK -> page 'PROMPT AdaGrace'")
    return "; ".join(out)


@t.flow("dialog-dismissed")
def dialog_dismissed(j):
    """A dialog the page closes itself: the phone's alert closes, unanswered.

    The page starts a navigation to a slow site, then shows an alert. When the navigation
    commits, Chromium drops the page's dialogs and the host tells the viewer
    (`rb.dialog.cancel`); the Mac's viewer closes its sheet the same way."""
    open_page(j)
    j.sim.tap(*at(j, "GONEPAGE"))
    alert = j.sim.wait(label="OK", kind="Button", timeout=SLOW_SECONDS)
    shown = time.time()
    j.sim.shot(f"dialog-dismissed-shown-{'before' if BEFORE else 'after'}")
    if BEFORE:
        return f"page alert while it navigates away: shown on the phone: {bool(alert)}"
    check(alert and j.sim.ocr_find("NAVALERT"), "the page's alert never showed")
    gone = None
    misses = 0
    while time.time() - shown < SLOW_SECONDS + 90:
        # Three reads in a row without the alert: one empty accessibility read is not "gone".
        misses = misses + 1 if not j.sim.find(label="OK", kind="Button") else 0
        if misses == 3:
            gone = time.time() - shown
            break
        time.sleep(0.5)
    j.sim.shot("dialog-dismissed-gone")
    check(gone is not None, "the alert stayed: no rb.dialog.cancel came (the page's navigation waits for its answer)")
    landed = ocr_wait(j, "FROM navigated", timeout=60)
    j.sim.shot("dialog-dismissed-navigated")
    check(landed is not None, "the phone did not show the page it navigated to")
    return (f"the page navigated away while its alert was open: the phone's alert closed by itself "
            f"{gone:.1f} s after it showed, unanswered (OK never tapped), and the new page showed")


@t.flow("select")
def select(j):
    """A <select>: its options in a sheet; a pick reaches the page."""
    open_page(j)
    j.sim.tap(*at(j, "Banana"))
    sheet = j.sim.wait(ident="browser.select.option.3", timeout=30) or j.sim.wait(label="Damson", timeout=2)
    j.sim.shot(f"select-{'before' if BEFORE else 'after'}")
    if BEFORE:
        return f"select: options on the phone: {bool(sheet)}"
    check(sheet, "no options sheet for the select")
    j.sim.tap_el(sheet)
    took = ocr_wait(j, "PICKED Damson", timeout=45)
    j.sim.shot("select-picked")
    check(took is not None, "the page did not get the pick")
    return f"select: the options sheet listed Apple..Damson; picking Damson reached the page in {took:.1f} s"


@t.flow("page-menu")
def page_menu(j):
    """Page menu: Hard Reload reloads the page; Open in Safari is offered for the web address."""
    open_page(j)
    j.sim.tap(*at(j, "PROMPTBTN"))
    ok = j.sim.wait(label="OK", kind="Button", timeout=30)
    if ok:
        j.sim.tap_el(ok)  # the page now reads "PROMPT Ada": a reload brings back "EVTPAGE ready"
    check(ocr_wait(j, "PROMPT", timeout=45) is not None or BEFORE, "the page did not change before the reload")
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
    took = ocr_wait(j, "EVTPAGE ready", timeout=45)
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


# page-menu goes last: it leaves the phone in Safari (each flow brings cmux back first).
ORDER = ["open-tab", "context-menu", "select", "dialogs", "dialog-dismissed", "page-menu"]


def readback(name, status, notes):
    """PQ_RAW/../data/<flow>.json: the result and the Mac's own record of this run's workspaces
    (each tab's kind and address, from the rig app's daemon)."""
    data = {"flow": name, "mode": "before" if BEFORE else "after", "status": status, "result": str(notes),
            "at": time.strftime("%Y-%m-%d %H:%M:%S"), "mac_workspaces": []}
    try:
        for ws in t.mac_tree().get("workspaces", []):
            if f"bev-{STAMP}" in (ws.get("name") or ""):
                data["mac_workspaces"].append({"name": ws.get("name"), "tabs": [
                    {"kind": tab.get("kind"), "url": tab.get("url"), "title": tab.get("title")} for _, tab in t.ws_tabs(ws)]})
    except Exception as error:  # noqa: BLE001 - a read-back that fails says so
        data["mac_error"] = str(error)
    out = os.path.join(os.path.dirname(pq.RAW.rstrip("/")), "data")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, f"{name}-{data['mode']}.json"), "w") as f:
        json.dump(data, f, indent=2)


def run(name):
    t0 = time.time()
    try:
        notes, ok = t.FLOWS[name](), True
        print(f"PASS {name} ({time.time() - t0:.0f} s): {notes}", flush=True)
    except Exception as error:  # noqa: BLE001 - a flow's failure is its result
        notes, ok = error, False
        print(f"FAIL {name} ({time.time() - t0:.0f} s): {error}", flush=True)
    try:
        readback(name, "pass" if ok else "fail", notes)
    except Exception as error:  # noqa: BLE001 - the read-back never changes the result
        print(f"  (read-back failed: {error})", flush=True)
    return ok


def run_all(names=None):
    return all([run(name) for name in (names or ORDER)])


def stop_site():
    """Stops the two servers serve() started, by the PIDs it recorded; never by name, so another
    run's server on this mini is left alone."""
    stops = []
    for pidfile in (f"http-{PORT}.pid", f"slow-{SLOW_PORT}.pid"):
        stops.append(f"p=$(cat {SITE}/{pidfile} 2>/dev/null) && kill \"$p\" 2>/dev/null; rm -f {SITE}/{pidfile}")
    pq.rsh("; ".join(stops) + "; true")


if __name__ == "__main__":
    import sys
    ok = run_all(sys.argv[1:] or None)
    subprocess.run(["true"])
    sys.exit(0 if ok else 1)
