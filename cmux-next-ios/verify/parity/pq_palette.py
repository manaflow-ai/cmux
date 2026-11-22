"""Navigation and search parity flows (feat-cmux-next-ios-palette-parity, cmux#25834 slices A-D):
the command palette (page menu, Cmd-K, Cmd-Shift-P), Search Tabs across every workspace (palette
and address bar), New Tab from Text, cmux links (Open Link in the palette, a link in a Chief
message), Jump to Latest Unread, Jump to Last Prompt, and Mute Chat Notifications.

Same rig as pq.py, pq_tabs.py and pq_crows.py: the phone app in ONE headless simulator, the real
tagged cmux-next Mac app (rmac.py), the real link between them. Every action under test is done
on the phone; after each one the Mac's state is read back from the rig app's own daemon socket
(`list-workspaces`) or acpmux socket (`_acpmux/sessions`, `_acpmux/events`). The palette and the
jumps are the phone's own navigation, so for them the check is what the phone shows, matched to
the Mac's ids (`workspace.<key>` and the tab's title).

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    . ~/cmux-next-ios-e2e/palette/env.sh && python3 -c 'import pq_palette as p; print(p.run("palette", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import subprocess
import time

import pq
import pq_crows as c
import pq_panes
import pq_rows as r
import pq_tabs as t
from journey import Fail, check

KEY = {"k": 14, "p": 19}
CMD, SHIFT = 227, 225


# ---------------------------------------------------------------- phone helpers

def labels(j):
    return r.labels(j)


def key_combo(key, modifiers):
    """A hardware key combination into the simulator (axe HID events; nothing on the Mac is driven)."""
    subprocess.run(["axe", "key-combo", "--modifiers", ",".join(map(str, modifiers)), "--key", str(KEY[key]),
                    "--udid", pq.load()["udid"]], capture_output=True, timeout=30)
    time.sleep(1.2)


def palette_open(j, timeout=6):
    return j.sim.wait(ident="palette", timeout=timeout) or j.sim.wait(label="Command Palette", timeout=2)


def palette_type(j, text):
    pq.type_text(text)
    time.sleep(1.5)


def palette_row(j, ident, timeout=8):
    row = j.sim.wait(ident=f"palette.row.{ident}", timeout=timeout)
    check(row, f"no palette row {ident!r}: {labels(j)[:30]}")
    return row


def on_workspace(j, key, timeout=20):
    """The phone shows the workspace page of Mac workspace `key`."""
    return j.sim.wait(ident=f"workspace.{key}", timeout=timeout) is not None


def shown_title(j, title, timeout=12):
    """The tab on screen is `title` (its title capsule or page)."""
    return j.sim.wait(contains=title, timeout=timeout) is not None


def tab_named(key, name):
    return next((tab for _, tab in t.ws_tabs(t.mac_workspace(key=key)) if tab.get("name") == name or tab.get("title") == name), None)


def rename_tab(ws, n, name):
    tab = t.ws_tabs(t.mac_workspace(key=ws["key"]))[n][1]
    t.mac_raw({"cmd": "rename-surface", "surface": tab["surface"], "name": name})
    return tab


# ---------------------------------------------------------------- flows

def palette(j, label):
    """The page menu's Command Palette…, its search, and a row that runs (Rename Tab…, then New
    Terminal from Cmd-K, then Cmd-Shift-P). Before: no palette row; Cmd-K does nothing."""
    ws = t.seed("palette", terminals=1)
    t.open_ws(j, ws["name"])
    out = {"page_menu": pq_panes.open_page_menu(j)}
    pq.shot(f"palette-{label}-page-menu")
    out["has_row"] = "Command Palette…" in out["page_menu"]
    if label == "before":
        pq_panes.close_menu(j)
        key_combo("k", [CMD])
        out["cmd_k_opens"] = palette_open(j, timeout=3) is not None
        pq.shot("palette-before-cmd-k")
        return out
    pq_panes.tap_row(j, "Command Palette…")
    check(palette_open(j), "the palette did not open")
    time.sleep(1)
    out["rows_open"] = labels(j)[:40]
    pq.shot("palette-after-open")
    palette_type(j, "rename")
    pq.shot("palette-after-search-rename")
    j.sim.tap_el(palette_row(j, "menu.Rename Tab…"))
    time.sleep(1.5)
    pq.type_text("palette-renamed")
    time.sleep(0.6)
    pq.shot("palette-after-rename-alert")
    r.tap(j, "Rename")
    _, took = t.until(lambda: tab_named(ws["key"], "palette-renamed"), timeout=20, what="the Mac to rename the tab")
    out["renamed_on_mac_s"] = round(took, 1)
    # Cmd-Shift-P (the Mac's key): New Terminal.
    before = len(t.ws_tabs(t.mac_workspace(key=ws["key"])))
    key_combo("p", [CMD, SHIFT])
    out["cmd_shift_p_opens"] = palette_open(j) is not None
    palette_type(j, "new terminal")
    pq.shot("palette-after-cmd-shift-p-search")
    j.sim.tap_el(palette_row(j, "new.terminal"))
    _, took = t.until(lambda: len(t.ws_tabs(t.mac_workspace(key=ws["key"]))) == before + 1, timeout=40,
                      what="a new terminal on the Mac")
    out["new_terminal_on_mac_s"] = round(took, 1)
    time.sleep(2)
    # Cmd-K on a terminal page stays the terminal's (Ghostty's Clear Screen): no palette.
    key_combo("k", [CMD])
    out["cmd_k_on_terminal_opens_palette"] = palette_open(j, timeout=3) is not None
    pq.shot("palette-after-cmd-k-terminal")
    out["mac_tabs"] = [tab.get("name") or tab.get("title") for _, tab in t.ws_tabs(t.mac_workspace(key=ws["key"]))]
    return out


def searchtabs(j, label):
    """Search Tabs across workspaces. A tab named `needle-*` lives in workspace B; the phone is in
    workspace A, editing a browser tab's address. Before: TabsKit's Switch to Tab lists this
    workspace only. After: Other Workspaces lists the needle, and the palette's Search Tabs finds it;
    each opens workspace B on that tab."""
    a = t.seed("search-a", terminals=1)
    b = t.seed("search-b", terminals=2)
    needle = f"needle-{time.strftime('%H%M%S')}"
    rename_tab(b, 1, needle)
    pane = t.ws_tabs(t.mac_workspace(key=a["key"]))[0][0]
    t.mac_raw({"cmd": "new-browser-tab", "pane": pane, "url": "https://example.com"})
    t.open_ws(j, a["name"])
    pq.open_grid(j)
    cards = [e for e in j.sim.find(suffix=", tab") if not (e.label or "").startswith("p2tabs-t")]
    check(cards, "no browser card")
    j.sim.tap_el(cards[0])
    time.sleep(3)
    addr = j.sim.wait(prefix="Address", kind="Button", timeout=10)
    check(addr, "no address field")
    j.sim.tap_el(addr)
    time.sleep(0.8)
    pq.type_text(needle)
    time.sleep(1.5)
    out = {"address_suggestions": labels(j)[:30]}
    pq.shot(f"searchtabs-{label}-address")
    out["address_finds_needle"] = any(needle in (x or "") for x in out["address_suggestions"])
    if label == "before":
        return out
    # The workspace screen's own identifier covers its rows' (SwiftUI), so the row is found by its text.
    hit = j.sim.wait(prefix=needle, kind="Button", timeout=8)
    check(hit, "no Other Workspaces row for the needle")
    j.sim.tap_el(hit)
    out["address_opens_b"] = on_workspace(j, b["key"])
    out["address_shows_needle"] = shown_title(j, needle)
    time.sleep(2)
    pq.shot("searchtabs-after-address-opened")
    # The palette's Search Tabs, from workspace A again.
    t.open_ws(j, a["name"])
    key_combo("p", [CMD, SHIFT])
    check(palette_open(j), "no palette")
    palette_type(j, needle)
    pq.shot("searchtabs-after-palette")
    rows = [e for e in j.sim.find() if (e.ident or "").startswith("palette.row.tab.")]
    out["palette_tab_rows"] = [e.label for e in rows]
    check(rows, "no tab rows in the palette")
    j.sim.tap_el(rows[0])
    out["palette_opens_b"] = on_workspace(j, b["key"])
    out["palette_shows_needle"] = shown_title(j, needle)
    time.sleep(2)
    pq.shot("searchtabs-after-palette-opened")
    return out


def fromtext(j, label):
    """New Tab from Text, typed in the palette's field: an address opens a browser tab at it on the
    Mac, `!cmd` a terminal with the command typed (not run), a prompt a new agent chat that sends it.
    Before: no palette (the same typed text reaches only TabsKit's address Search)."""
    ws = t.seed("fromtext", terminals=1)
    key = ws["key"]
    kinds = lambda: [tab.get("kind") for _, tab in t.ws_tabs(t.mac_workspace(key=key))]
    t.open_ws(j, ws["name"])
    out = {}
    if label == "before":
        out["page_menu"] = pq_panes.open_page_menu(j)
        out["has_palette"] = "Command Palette…" in out["page_menu"]
        pq.shot("fromtext-before-page-menu")
        pq_panes.close_menu(j)
        return out
    # An address.
    key_combo("p", [CMD, SHIFT])
    check(palette_open(j), "no palette")
    palette_type(j, "example.org/text")
    out["address_rows"] = [e.label for e in j.sim.find() if (e.ident or "").startswith("palette.row.newTab.")]
    pq.shot("fromtext-after-address-rows")
    j.sim.tap_el(palette_row(j, "newTab.address"))
    got, took = t.until(lambda: next((tab.get("url") for _, tab in t.ws_tabs(t.mac_workspace(key=key))
                                      if tab.get("kind") == "browser" and "example.org" in (tab.get("url") or "")), None),
                        timeout=40, what="a browser tab at example.org on the Mac")
    out["browser_url"], out["browser_s"] = got, round(took, 1)
    time.sleep(3)
    pq.shot("fromtext-after-browser")
    # A command.
    before = kinds().count("pty")
    key_combo("p", [CMD, SHIFT])
    check(palette_open(j), "no palette")
    palette_type(j, "!echo from-text-$((6*7))")
    pq.shot("fromtext-after-command-rows")
    j.sim.tap_el(palette_row(j, "newTab.terminal"))
    _, took = t.until(lambda: kinds().count("pty") == before + 1, timeout=40, what="a new terminal on the Mac")
    out["terminal_s"] = round(took, 1)
    time.sleep(3)
    out["terminal_composer"] = [e.value for e in j.sim.find(kind="TextArea")] + [e.value for e in j.sim.find(kind="TextView")]
    pq.shot("fromtext-after-terminal")
    # A prompt.
    sessions = {s["sessionId"] for s in c.sessions()}
    key_combo("p", [CMD, SHIFT])
    check(palette_open(j), "no palette")
    palette_type(j, "Reply with exactly the word PALETTE and nothing else.")
    pq.shot("fromtext-after-prompt-rows")
    j.sim.tap_el(palette_row(j, "newTab.chat"))
    made, took = t.until(lambda: [s for s in c.sessions() if s["sessionId"] not in sessions], timeout=90,
                         what="a new acpmux session on the Mac")
    sid = made[0]["sessionId"]
    out["chat_session"], out["chat_s"] = sid, round(took, 1)
    # The Mac is the truth: the chat's tab in this workspace, its prompt in acpmux, then the reply.
    _, took = t.until(lambda: any(((x.get("conversation") or {}).get("agent_session") or {}).get("session") == sid
                                  for _, x in t.ws_tabs(t.mac_workspace(key=key))), timeout=60, what="the chat's tab on the Mac")
    out["chat_tab_s"] = round(took, 1)
    prompts, took = t.until(lambda: [p["text"] for p in c.prompts(sid)], timeout=60, what="the prompt in acpmux")
    out["acpmux_prompts"], out["prompt_s"] = prompts, round(took, 1)
    out["reply"] = t.until(lambda: (lambda s: (s.get("lastMessage") or {}).get("text") if s and s.get("lastMessage", {}).get("role") == "agent" else None)(c.session(sid)),
                           timeout=240, what="the agent's reply")[0]
    pq.shot("fromtext-after-chat")
    return out


def links(j, label):
    """cmux links. Open Link in the palette (a pasted `cmux://tab/…` of another workspace), and a
    `cmux://` link in a Chief message tapped on the phone. The links open what they name: the
    phone's routing landed in 8c9b49c5 (verify/deep-links.md); the base shows the Chief tap already
    works and has no Open Link."""
    a = t.seed("links-a", terminals=1)
    b = t.seed("links-b", terminals=2)
    target = rename_tab(b, 1, f"linked-{time.strftime('%H%M%S')}")
    tree_b = t.mac_workspace(key=b["key"])
    tab_id = next(tab.get("tab_resource_id") for _, tab in t.ws_tabs(tree_b) if tab["surface"] == target["surface"])
    link = f"cmux://tab/{tab_id}"
    out = {"link": link}
    t.open_ws(j, a["name"])
    if label == "after":
        key_combo("p", [CMD, SHIFT])
        check(palette_open(j), "no palette")
        palette_type(j, link)
        pq.shot("links-after-open-link-row")
        j.sim.tap_el(palette_row(j, "link.open"))
        out["open_link_opens_b"] = on_workspace(j, b["key"])
        time.sleep(2)
        pq.shot("links-after-open-link-opened")
    # Simulator's URL handler: the same link from outside the app (Safari, Messages, Notes).
    subprocess.run(["xcrun", "simctl", "openurl", pq.load()["udid"], f"cmux://workspace/{tree_b.get('resource_id')}"],
                   capture_output=True, timeout=30)
    time.sleep(2)
    ok = j.sim.wait(label="Open", kind="Button", timeout=5)
    if ok:
        j.sim.tap_el(ok)
    out["outside_link_opens_b"] = on_workspace(j, b["key"])
    time.sleep(1.5)
    pq.shot(f"links-{label}-outside")
    return out


def jumps(j, label):
    """Jump to Latest Unread and Jump to Last Prompt. The Mac: a notification in workspace U's
    terminal (OSC 9 from its shell, unread), a terminal agent prompted in workspace P. The phone
    is in workspace A. Before: no palette rows and no key. After: each jump opens that tab.
    Last Prompt follows the Mac's agent roster (terminal agents), as the Mac's action does."""
    a = t.seed("jump-a", terminals=1)
    u = t.seed("jump-unread", terminals=1)
    p = t.seed("jump-prompt", terminals=1)
    out = {}
    if label == "before":
        t.open_ws(j, a["name"])
        out["page_menu"] = pq_panes.open_page_menu(j)
        out["has_jump"] = any("Jump to" in x for x in out["page_menu"])
        pq.shot("jumps-before-page-menu")
        pq_panes.close_menu(j)
        return out
    # The Mac's Jump to Last Prompt reads its agent roster (`agent-changed`: terminal agents such as
    # Claude Code or Codex in a terminal, which report through `report-agent`); an acpmux chat tab
    # reports nothing there. Rig setup on the Mac: P's terminal reports a turn the person prompted,
    # as a terminal Claude Code's hook does (idle, then working).
    p_surface = t.ws_tabs(t.mac_workspace(key=p["key"]))[0][1]["surface"]
    for state in ("idle", "working"):
        t.mac_raw({"cmd": "report-agent", "surface": p_surface, "state": state, "agent": "claude",
                   "source": "socket", "session": f"palette-{time.strftime('%H%M%S')}"})
    out["mac_agents"] = t.mac_raw({"cmd": "list-agents"}).get("agents")
    surface = t.ws_tabs(t.mac_workspace(key=u["key"]))[0][1]["surface"]
    t.mac_raw({"cmd": "send", "surface": surface, "text": "printf '\\033]9;palette-unread\\007'\r"})
    marker, took = t.until(lambda: (lambda tab: tab.get("notification") if tab and (tab.get("notification") or {}).get("unread") else None)(
        next((x for _, x in t.ws_tabs(t.mac_workspace(key=u["key"])) if x["surface"] == surface), None)), timeout=30,
        what="an unread notification on the Mac")
    out["mac_marker"] = marker
    t.open_ws(j, a["name"])
    key_combo("p", [CMD, SHIFT])
    check(palette_open(j), "no palette")
    palette_type(j, "jump")
    pq.shot("jumps-after-rows")
    out["rows"] = [e.label for e in j.sim.find() if (e.ident or "").startswith("palette.row.jump")]
    j.sim.tap_el(palette_row(j, "jumpToUnread"))
    out["unread_opens_u"] = on_workspace(j, u["key"])
    time.sleep(2)
    pq.shot("jumps-after-unread")
    t.open_ws(j, a["name"])
    key_combo("p", [CMD, SHIFT])
    check(palette_open(j), "no palette")
    palette_type(j, "last prompt")
    j.sim.tap_el(palette_row(j, "jumpToLastPrompt"))
    out["prompt_opens_p"] = on_workspace(j, p["key"])
    time.sleep(2)
    pq.shot("jumps-after-last-prompt")
    return out


def push(j, sid, macid, ws_key, title):
    """A finished-turn push for chat `sid`, in through `simctl push` (a simulator has no APNs token)."""
    body = {"aps": {"alert": {"title": title, "body": "The agent finished its turn."}, "sound": "default"},
            "cmuxMobile": {"v": 2, "mac": macid, "kind": "completed", "sessionId": sid, "workspaceId": ws_key,
                           "title": title, "body": "The agent finished its turn."}}
    path = "/tmp/palette-push.json"
    json.dump(body, open(path, "w"))
    st = pq.load()
    subprocess.run(["xcrun", "simctl", "push", st["udid"], pq.BUNDLE, path], capture_output=True, timeout=30)


def allow_notifications(j):
    """The Demo build asks for notifications only when told to (a simulator has no APNs token): a
    relaunch with the simulated service push asks, and the rig taps Allow. A no-op once allowed."""
    body = {"aps": {"alert": {"title": "Notifications on", "body": "rig setup"}}}
    j.sim.launch(pq.BUNDLE, env={"CMUX_MOBILE_DEV_SERVICE_PUSH": json.dumps(body)})
    allow = j.sim.wait(label="Allow", kind="Button", timeout=6)
    if allow:
        j.sim.tap_el(allow)
    time.sleep(6)  # the setup banner goes away before the run
    fresh(j)


def banner(j, title):
    """The banner's text read off the screen (SpringBoard's banner is not in the app's tree)."""
    return [hit[4] for hit in j.sim.ocr_find(title, timeout=2.5)]


def mute(j, label):
    """Mute Chat Notifications, phone-local. A phone-started chat; its page menu's Mute row; then a
    push for that chat while the phone shows another workspace: no banner. Unmute: the banner shows.
    Before: no Mute row; the push shows its banner."""
    allow_notifications(j)
    m = t.seed("mute-chat", terminals=1)
    a = t.seed("mute-away", terminals=1)
    c.start_phone_chat(j, m["name"])
    c.ask(j, "Reply with exactly the word QUIET and nothing else.", "QUIET")
    sid = c.tab_sessions(m["key"])
    sid = list(sid.values())[-1]
    out = {"session": sid, "page_menu": c.page_menu(j)}
    out["has_mute"] = "Mute Chat Notifications" in out["page_menu"]
    pq.shot(f"mute-{label}-page-menu")
    macid = pq.load()["device_id"]
    if label == "after":
        c.page_row(j, "Mute Chat Notifications")
        time.sleep(1.5)
        out["toast"] = [e.label for e in j.sim.find(contains="quietly")]
        pq.shot("mute-after-toast")
    else:
        pq_panes.close_menu(j)
    t.open_ws(j, a["name"])
    push(j, sid, macid, m["key"], "Muted chat finished")
    out["banner_muted"] = banner(j, "Muted chat finished")
    pq.shot(f"mute-{label}-push")
    if label == "before":
        return out
    t.open_ws(j, m["name"])
    out["page_menu_muted"] = c.page_menu(j)
    c.page_row(j, "Unmute Chat Notifications")
    time.sleep(1.5)
    t.open_ws(j, a["name"])
    push(j, sid, macid, m["key"], "Unmuted chat finished")
    out["banner_unmuted"] = banner(j, "Unmuted chat finished")
    pq.shot("mute-after-unmuted-push")
    return out


FLOWS = {"palette": palette, "searchtabs": searchtabs, "fromtext": fromtext, "links": links, "jumps": jumps, "mute": mute}


def fresh(j):
    """Each flow starts on the Workspaces list of a relaunched app (it reconnects to the rig Mac over
    the real link). The rig's own seeds pile up in the list, so the list itself is the check."""
    j.sim.launch(pq.BUNDLE)
    time.sleep(4)
    j.back_to_list()
    check(j.sim.wait(ident="workspaces.list", timeout=30), "no Workspaces list after a relaunch")


def run(name, label):
    sim, mac, j = pq.ctx()
    fresh(j)
    pq.rec_start(f"{name}-{label}")
    try:
        out = FLOWS[name](j, label)
    finally:
        pq.rec_stop()
    os.makedirs(pq.ART, exist_ok=True)
    json.dump(out, open(os.path.join(pq.ART, f"{name}-{label}.json"), "w"), indent=2)
    return out
