#!/usr/bin/env python3
"""A fake `cmux` for tests/toolpack_gdocs.rs: one browser tab on a Google Doc.

It answers the calls the gdocs tool makes (`cmux --json open URL`,
`cmux --json browser TAB eval|wait|navigate ...`) the way the Docs editor
does: a paste of HTML replaces the selection, select-all selects the body,
Cmd+Up/Down move the caret to an end, find puts the caret on a match, and
/mobilebasic serves the saved body. State lives in $GDOCS_FAKE_STATE (JSON);
every call is appended to $GDOCS_FAKE_LOG.

GDOCS_FAKE_FLATTEN=1 makes the editor drop list nesting on paste (the fault
verify must catch).
"""

import json
import os
import re
import sys

state_path = os.environ["GDOCS_FAKE_STATE"]
log_path = os.environ.get("GDOCS_FAKE_LOG")


def load():
    try:
        with open(state_path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"url": "about:blank", "lib": False, "mode": "editing", "doc": "", "sel": "end",
                "comments": [], "ready": {}}


def save(s):
    with open(state_path, "w") as f:
        json.dump(s, f)


def out(v):
    print(json.dumps({"tab": "tab_fake", "value": v}))


def plain(html):
    return re.sub(r"<[^>]+>", "", html)


args = sys.argv[1:]
if args and args[0] == "--json":
    args = args[1:]
if log_path:
    with open(log_path, "a") as f:
        f.write(json.dumps(args) + "\n")
s = load()

if args[0] == "open":
    s["url"] = args[1]
    save(s)
    print(json.dumps({"tab_id": "tab_fake", "created": ["tab_fake"]}))
    sys.exit(0)

assert args[0] == "browser", args
verb = args[2]
if verb == "navigate":
    s["url"] = args[3]
    s["lib"] = False
    save(s)
    out(None)
    sys.exit(0)
if verb == "wait":
    fn = args[args.index("--function") + 1] if "--function" in args else ""
    if "[1-9]" in fn and not (s.get("q") and plain(s["doc"]).count(s["q"])):
        print(json.dumps({"code": "timeout", "message": "wait timed out"}))
        sys.exit(1)
    out(True)
    sys.exit(0)
if verb != "eval":
    print(f"fake cmux: no verb {verb}", file=sys.stderr)
    sys.exit(2)

js = args[3]
if js == "location.href":
    out(s["url"])
elif "window.__cmuxGdocs.v===" in js:
    out(s["lib"])
elif "const G=window.__cmuxGdocs={v:" in js:
    s["lib"] = True
    out("ok")
elif "G.mode()" in js:
    out(s["mode"])
elif m := re.search(r"G\.setMode\('(\w+)'\)", js):
    s["mode"] = m.group(1)
    out(s["mode"])
elif "G.selectAll()" in js:
    s["sel"] = "all"
    out(1)
elif "G.toEnd()" in js:
    s["sel"] = "end"
    out(1)
elif "G.toStart()" in js:
    s["sel"] = "start"
    out(1)
elif "G.suggestions()" in js:
    out([f"Add: \u201c{plain(h)}\u201d" for h in s.get("suggestions", [])])
elif "G.openFind()" in js:
    out(True)
elif m := re.search(r"G\.findSet\((\".*\")\)", js):
    s["q"] = json.loads(m.group(1))
    out(1)
elif "window.__cmuxGdocs.findCount()" in js:
    out(plain(s["doc"]).count(s.get("q", "")) > 0)
elif "G.findGo()" in js:
    needle = s.get("q", "")
    hits = plain(s["doc"]).count(needle) if needle else 0
    if hits:
        s["sel"] = "find:" + needle
    out(f"1 of {hits}" if hits else "")
elif "G.right()" in js:
    if s["sel"].startswith("find:"):
        s["sel"] = "after:" + s["sel"][5:]
    out(1)
elif m := re.search(r"G\.paste\((\".*?(?<!\\)\"),(\".*\")\),1\)", js):
    html = json.loads(m.group(1))
    if os.environ.get("GDOCS_FAKE_FLATTEN") == "1":
        html = re.sub(r"</?ul>", "", html)
        html = "<ul>" + html + "</ul>" if "<li>" in html else html
    sel = s["sel"]
    if s["mode"] == "suggesting":
        s.setdefault("suggestions", []).append(html.strip())
        s["sel"] = "end"
        out(1)
        save(s)
        sys.exit(0)
    if sel == "all":
        s["doc"] = html
    elif sel == "start":
        s["doc"] = html + s["doc"]
    elif sel.startswith("after:"):
        needle = sel[6:]
        i = s["doc"].find(needle)
        s["doc"] = s["doc"][:i + len(needle)] + html + s["doc"][i + len(needle):]
    else:
        s["doc"] += html
    s["sel"] = "end"
    out(1)
elif m := re.search(r"G\.comment\((\".*\")\)", js):
    s["comments"].append(json.loads(m.group(1)))
    out("posted")
elif m := re.search(r"G\.fetchBasic\(\"([^\"]+)\",\"([^\"]+)\"\)", js):
    s["ready"][m.group(2)] = True
    out(1)
elif m := re.search(r"window\.__cmuxGdocs&&window\.__cmuxGdocs\.r\[\"([^\"]+)\"\]", js):
    out(True)
elif m := re.search(r"const v=R\[\"([^\"]+)\"\]", js):
    notes = "".join(f'<div><p><a href="#cmnt_ref{i + 1}" id="cmnt{i + 1}">[{chr(97 + i)}]</a><span>{c}</span></p></div>'
                    for i, c in enumerate(s["comments"]))
    page = f'<html><body><div class="doc-content">{s["doc"]}{notes}</div></body></html>'
    out({"ok": True, "status": 200, "url": "https://docs.google.com/document/d/x/mobilebasic", "html": page})
else:
    print(f"fake cmux: unknown eval {js[:120]!r}", file=sys.stderr)
    sys.exit(3)
save(s)
