"""Browser addresses over the real link (PROTOCOL.md `browser` "Addresses", PR #24140).

The iOS app in ONE headless simulator, the real tagged cmux-next Mac app hidden on a cmux
mini (rmac.py there). Each flow is recorded to PQ_RAW/<name>.mp4.

    PQ_RBASE=~/cmux-next-ios-e2e/brschemes PQ_TAG=brschemes PQ_SIM=brschemes-phone \\
    PQ_STATE=~/cmux-next-ios-e2e/brschemes/state.json PQ_RAW=~/cmux-next-ios-e2e/brschemes/raw \\
    python3 -c 'import pq_browser_schemes as b; b.run_all()'

- mac-file: the Mac opens a `file:` page outside every shared folder in its own browser
  tab; the phone streams it (no "only http, https and about:blank load").
- typed: in a phone browser tab, a `file:` page in the workspace folder loads, one outside
  says "This file isn't in a folder this Mac shares with your iPhone.", `data:` loads and
  `javascript:` says "Scripts can't run from your iPhone's address bar."
"""
import os
import subprocess
import shlex
import time

import pq
import pq_tabs as t
from journey import check

STAMP = "7" + time.strftime("%H%M%S")
# Page bodies are matched by words that are never in a workspace name or an address
# (review finding: the stamp alone also shows in the tab's name and URL).
BODY = "ZQ" + time.strftime("%M%S")
PAGES = f"{pq.RBASE}/macpages"  # not a workspace folder: only the Mac's own tab may show it


def write_page(path, title, body):
    html = f"<!doctype html><title>{title}</title><body style='font:28px -apple-system;padding:24px'><p>{body}</p></body>"
    r = pq.rsh(f"mkdir -p $(dirname {path}) && printf %s {shlex.quote(html)} > {path} && cd $(dirname {path}) && pwd -P")
    check(r.returncode == 0, f"write {path}: {r.stderr.strip()[:200]}")
    return f"{r.stdout.strip()}/{os.path.basename(path)}"


def ocr_wait(j, needle, timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if j.sim.ocr_find(needle):
            return time.time() - t0
        time.sleep(1)
    return None


def go(j, address):
    addr = j.sim.wait(prefix="Address", kind="Button", timeout=10)
    check(addr, "no address field")
    j.sim.tap_el(addr)
    time.sleep(0.8)
    pq.type_text(address + "\n")
    time.sleep(1.5)


def notice(j):
    """The refusal over the page (accessibility first, then the screen's text)."""
    e = j.sim.find(ident="browser.refused") or j.sim.find(contains="Mac shares") or j.sim.find(contains="Scripts can")
    if e and e[0].label:
        return e[0].label
    return " ".join(o[4] for o in j.sim.ocr())


@t.flow("mac-file")
def mac_file(j):
    path = write_page(f"{PAGES}/iphone-link-sequence-{STAMP}.html", "Mac page", f"MPGX {BODY}")
    a = t.seed(f"brs-mac-{STAMP}", terminals=1)
    pane = t.ws_tabs(a)[0][0]
    t.mac_raw({"cmd": "new-browser-tab", "url": f"file://{path}", "pane": pane})
    t.open_ws(j, a["name"])
    took = ocr_wait(j, "MPGX", timeout=45)
    pill = j.sim.ocr_find("only http")
    j.sim.shot("mac-file")
    check(not pill, "the phone shows the old scheme pill")
    check(took is not None, "the Mac's file page never showed on the phone")
    return f"the Mac's own tab at file://{path} (outside every shared folder) streamed in {took:.1f} s"


@t.flow("typed")
def typed(j):
    proj = pq.rsh(f"mkdir -p {t.PROJ} && cd {t.PROJ} && pwd -P").stdout.strip()
    shared = write_page(f"{proj}/shared-{STAMP}.html", "Shared page", f"SPGX {BODY}")
    outside = write_page(f"{PAGES}/outside-{STAMP}.html", "Outside page", f"OPGX {BODY}")
    a = t.seed(f"brs-typed-{STAMP}", terminals=1)
    t.open_ws(j, a["name"])
    pq.plus_menu(j, "New Browser Tab")
    pq.wait_opened(j, timeout=120)
    out = []
    go(j, f"file://{shared}")
    took = ocr_wait(j, "SPGX")
    j.sim.shot("typed-shared")
    check(took is not None, "a file in the workspace folder did not load")
    out.append(f"shared file loaded in {took:.1f} s")
    go(j, f"file://{outside}")
    time.sleep(2)
    said = notice(j)
    j.sim.shot("typed-outside")
    check("isn't in a folder this Mac shares" in said, f"outside file: notice {said!r}")
    check(not j.sim.ocr_find("OPGX"), "the outside file's content showed")
    out.append(f"outside file: {said!r}")
    go(j, "data:text/html,<h1>DATAOK42</h1>")
    took = ocr_wait(j, "DATAOK42")
    j.sim.shot("typed-data")
    check(took is not None, "data: did not load")
    out.append(f"data: loaded in {took:.1f} s")
    go(j, "javascript:alert(1)")
    time.sleep(2)
    said = notice(j)
    j.sim.shot("typed-javascript")
    check("Scripts can't run" in said, f"javascript: notice {said!r}")
    out.append(f"javascript: {said!r}")
    return "; ".join(out)


# The keyboard flow first: `typed` uses axe (hardware key events), after which the
# simulator shows only the key bar, never the software keyboard.
ORDER = ["keyboard", "mac-file", "typed"]


def run(name):
    t0 = time.time()
    try:
        notes = t.FLOWS[name]()
        print(f"PASS {name} ({time.time() - t0:.0f} s): {notes}", flush=True)
        return True
    except Exception as error:  # noqa: BLE001 - a flow's failure is its result
        print(f"FAIL {name} ({time.time() - t0:.0f} s): {error}", flush=True)
        return False


def run_all():
    return all([run(name) for name in ORDER])


# ---------------------------------------------------------------- keyboard (the floating button)

FORM = """<!doctype html><title>Form</title><body style='font:28px -apple-system;padding:20px'>
<form onsubmit="document.getElementById('out').textContent='SENT '+document.getElementById('a').value+' / '+document.getElementById('b').value;return false">
<p>Name <input id=a style='font:28px -apple-system;width:90%'></p>
<p>City <input id=b style='font:28px -apple-system;width:90%'></p>
<button style='font:28px -apple-system'>Send</button></form><h1 id=out></h1></body>"""


def keyboard_up(j, timeout=15):
    t0 = time.time()
    while time.time() - t0 < timeout:
        j.sim.dismiss_keyboard_intro()
        if j.sim.keyboard():
            return True
        time.sleep(0.5)
    return False


def open_keyboard(j):
    k = j.sim.wait(label="Keyboard", kind="Button", timeout=10)
    check(k, "no Keyboard button on the page")
    j.sim.tap_el(k)
    check(keyboard_up(j), "the Keyboard button did not bring up the keyboard")
    check(j.sim.find(ident="browser.key.tab") or j.sim.find(label="Tab", kind="Button"), "no key bar above the keyboard")
    time.sleep(1)  # the keyboard's slide-in, before taps on its bar


def bar(j, label):
    e = j.sim.wait(label=label, kind="Button", timeout=5)
    check(e, f"no {label!r} on the key bar")
    j.sim.tap_el(e)
    time.sleep(0.6)


@t.flow("keyboard")
def keyboard(j):
    out = []
    a = t.seed(f"brs-kbd-{STAMP}", terminals=1)
    pane = t.ws_tabs(a)[0][0]
    t.mac_raw({"cmd": "new-browser-tab", "url": "https://duckduckgo.com/", "pane": pane})
    t.open_ws(j, a["name"])
    check(ocr_wait(j, "DuckDuckGo", timeout=45) is not None, "duckduckgo.com never showed")
    # The search box (CSS ~ y 148 on a 402-wide page), then the keyboard button.
    j.sim.tap(90, 148)
    time.sleep(1)
    open_keyboard(j)
    out.append("keyboard + key bar up")
    j.sim.softtype("cmux terminal\n")
    took = ocr_wait(j, "cmux.com", timeout=30) or ocr_wait(j, "github", timeout=10)
    j.sim.shot("keyboard-search")
    check(took is not None, "typing + Return did not search")
    out.append("typed a search and Return: results")
    bar(j, "Hide Keyboard")
    check(not keyboard_up(j, timeout=2), "Hide Keyboard left the keyboard up")
    # A form in the workspace folder: type, Tab to the next field, Return to submit.
    proj = pq.rsh(f"mkdir -p {t.PROJ} && cd {t.PROJ} && pwd -P").stdout.strip()
    pq.rsh(f"printf %s {shlex.quote(FORM)} > {proj}/form-{STAMP}.html")
    # The address bar with the soft keyboard (axe's hardware keys would switch the
    # simulator to a hardware keyboard, which shows only the key bar).
    addr = j.sim.wait(prefix="Address", kind="Button", timeout=10)
    j.sim.tap_el(addr)
    time.sleep(1)
    j.sim.softtype(f"file://{proj}/form-{STAMP}.html\n")
    check(ocr_wait(j, "City", timeout=20) is not None, "the form never showed")
    j.sim.tap(200, 169)  # the Name field
    time.sleep(0.8)
    open_keyboard(j)
    j.sim.softtype("Ada")
    bar(j, "Tab")
    j.sim.softtype("Paris\n")
    took = ocr_wait(j, "SENT Ada", timeout=15)  # "SENT Ada / Paris" wraps at this size
    check(took is None or j.sim.ocr_find("Paris"), "the City field did not get Paris")
    j.sim.shot("keyboard-form")
    check(took is not None, "the form did not get both fields")
    out.append("form: Name, Tab, City, Return -> 'SENT Ada / Paris'")
    # Select All from the bar, then typing replaces the City field's text.
    bar(j, "Select All")
    j.sim.softtype("Rome\n")
    took = ocr_wait(j, "Rome", timeout=15)
    j.sim.shot("keyboard-select-all")
    check(took is not None and not j.sim.ocr_find("Paris"), "Select All + typing did not replace the field")
    out.append("Select All from the bar, typed over: 'SENT Ada / Rome'")
    bar(j, "Hide Keyboard")
    return "; ".join(out)


# ---------------------------------------------------------------- the host's own checks (rb.file_policy, rb.text_input)

def embed_page(secret_path, image_path, css_path):
    """A shared page that embeds files outside the shared folders four ways: an
    iframe, an image, a stylesheet and fetch. Each would put LEAKED on screen."""
    return f"""<!doctype html><title>Embeds</title>
<link rel=stylesheet href='file://{css_path}'>
<body style='font:28px -apple-system;padding:20px'>
<p>EMBEDHOST {BODY}</p><p id=css></p>
<img src='file://{image_path}' style='width:340px;height:90px'>
<iframe src='file://{secret_path}' style='width:90%;height:120px'></iframe>
<p id=f>fetch: waiting</p>
<script>fetch('file://{secret_path}').then(r=>r.text()).then(t=>document.getElementById('f').textContent='fetch: '+t)
.catch(()=>document.getElementById('f').textContent='fetch: BLOCKED')</script></body>"""


@t.flow("embedded")
def embedded(j):
    proj = pq.rsh(f"mkdir -p {t.PROJ} && cd {t.PROJ} && pwd -P").stdout.strip()
    secret = write_page(f"{PAGES}/secret-{STAMP}.html", "Secret", f"LEAKED {BODY}")
    svg = ("<svg xmlns='http://www.w3.org/2000/svg' width='340' height='90'>"
           "<text x='10' y='60' font-size='48' font-family='Helvetica'>LEAKED</text></svg>")
    css = "#css::after { content: 'LEAKED CSS'; font-size: 40px }"
    pages = pq.rsh(f"cd {PAGES} && pwd -P").stdout.strip()
    pq.rsh(f"printf %s {shlex.quote(svg)} > {pages}/secret-{STAMP}.svg && printf %s {shlex.quote(css)} > {pages}/secret-{STAMP}.css")
    page = embed_page(secret, f"{pages}/secret-{STAMP}.svg", f"{pages}/secret-{STAMP}.css")
    pq.rsh(f"printf %s {shlex.quote(page)} > {proj}/embeds-{STAMP}.html")
    a = t.seed(f"brs-embed-{STAMP}", terminals=1)
    t.open_ws(j, a["name"])
    pq.plus_menu(j, "New Browser Tab")
    pq.wait_opened(j, timeout=120)
    go(j, f"file://{proj}/embeds-{STAMP}.html")
    check(ocr_wait(j, "EMBEDHOST", timeout=30) is not None, "the shared page did not load")
    time.sleep(3)
    j.sim.shot("embedded")
    leaked = j.sim.ocr_find("LEAKED")
    check(not leaked, "a file outside the shared folders showed inside the shared page")
    return ("a shared page's iframe, image, stylesheet and fetch of files outside the shared folders "
            "show nothing (no 'LEAKED' on screen)")


FOCUS = """<!doctype html><title>Focus</title><body style='font:28px -apple-system;padding:20px'>
<p>FOCUSPAGE <span id=out></span></p><button id=b style='font:28px -apple-system' onclick="document.getElementById('i').focus()">Focus the field</button>
<p style='margin-top:420px'>Field <input id=i style='font:28px -apple-system;width:90%'></p>
<script>document.getElementById('i').addEventListener('keydown',e=>{
if(e.key.startsWith('Arrow'))document.getElementById('out').textContent='KEY '+e.key})</script></body>"""


@t.flow("focus")
def focus(j):
    out = []
    proj = pq.rsh(f"mkdir -p {t.PROJ} && cd {t.PROJ} && pwd -P").stdout.strip()
    pq.rsh(f"printf %s {shlex.quote(FOCUS)} > {proj}/focus-{STAMP}.html")
    a = t.seed(f"brs-focus-{STAMP}", terminals=1)
    pane = t.ws_tabs(a)[0][0]
    t.mac_raw({"cmd": "new-browser-tab", "url": f"file://{proj}/focus-{STAMP}.html", "pane": pane})
    t.open_ws(j, a["name"])
    check(ocr_wait(j, "FOCUSPAGE", timeout=45) is not None, "the focus page did not load")
    def raised(timeout):
        """The keyboard (or, with a hardware keyboard attached, only its key bar) is up."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            if j.sim.find(ident="browser.key.tab") or j.sim.keyboard():
                return True
            time.sleep(0.5)
        return False

    check(not raised(2), "the keyboard was up before any field had focus")
    j.sim.tap(120, 196)  # the button: the page focuses a field below the fold
    check(raised(10), "the keyboard did not rise when the page focused a field")
    time.sleep(1.5)
    j.sim.shot("focus-raised")
    check(j.sim.ocr_find("Field"), "the focused field is not in view above the keyboard")
    out.append("page focus raised the keyboard; the field stays in view")
    if j.sim.keyboard():
        j.sim.softtype("abc")
    else:
        pq.type_text("abc")
    took = ocr_wait(j, "abc", timeout=10)
    check(took is not None, "typing did not reach the focused field")
    out.append("typed into it")
    return "; ".join(out)


@t.flow("hardware-keys")
def hardware_keys(j):
    """axe sends hardware key events: arrows reach the page's own keydown handler."""
    proj = pq.rsh(f"mkdir -p {t.PROJ} && cd {t.PROJ} && pwd -P").stdout.strip()
    a = t.seed(f"brs-hw-{STAMP}", terminals=1)
    pane = t.ws_tabs(a)[0][0]
    t.mac_raw({"cmd": "new-browser-tab", "url": f"file://{proj}/focus-{STAMP}.html", "pane": pane})
    t.open_ws(j, a["name"])
    check(ocr_wait(j, "FOCUSPAGE", timeout=45) is not None, "the focus page did not load")
    j.sim.tap(120, 196)
    time.sleep(2)
    subprocess.run(["axe", "key", "80", "--udid", pq.load()["udid"]], capture_output=True, timeout=30)  # left arrow
    took = ocr_wait(j, "ArrowLeft", timeout=10)  # "KEY ArrowLeft" wraps
    j.sim.shot("hardware-arrow")
    check(took is not None, "a hardware arrow did not reach the page")
    return "a hardware Left Arrow reached the page's keydown ('KEY ArrowLeft')"


HOST_ORDER = ["focus", "embedded", "hardware-keys"]


def run_host():
    return all([run(name) for name in HOST_ORDER])
