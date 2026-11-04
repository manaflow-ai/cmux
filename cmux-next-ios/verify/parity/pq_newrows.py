"""New Mac rows parity flows (feat-cmux-next-ios-new-mac-rows-parity, cmux#25834: Mac features
after 2026-10-26): Settings → Automations and Artifacts (the account's own cmux Cloud calls),
Home's Delete Conversation from List / Show Hidden Conversations, the next-step card, Continue on
a failed turn, New Agent Chat on…, Move Workspace Above… / Below…, Reveal in Workspaces List,
Compact Workspace List, Toggle Prompt Queueing, Long-Press Menus, Copy Logs, Connect GitHub and
Fork Conversation to New Column Right.

Same rig as pq.py, pq_rows.py and pq_crows.py: the phone app in ONE headless simulator on the rig
mini, the real tagged cmux-next Mac app (rmac.py), the real link between them. Every action under
test is done on the phone; the result is read back from the Mac (its daemon, acpmux socket or
CLI) or from the account's Cloud service, never from the phone's own state. Both apps sign in as
the dev test account (`~/.secrets/cmux-dev-agent-auth.env`, copied 0600 to the rig and given to
the phone through its DEBUG launch environment, never printed); the phone's Cloud calls go to the
development Worker (`PQ_PHONE_ENV`).

Run ON the rig mini (PQ_HOST=local), one flow at a time, each recorded to PQ_RAW/<flow>-<label>.mp4:

    . ~/cmux-next-ios-e2e/newrows/env.sh && python3 -c 'import pq_newrows as n; print(n.run("automations", "after"))'

`label` is `before` (the base app: the gap) or `after` (this branch).
"""
import json
import os
import shlex
import subprocess
import time

import pq
import pq_crows as c
import pq_panes as p
import pq_rows as r
import pq_tabs as t
import pq_ws as w
from journey import Fail, check

PREFIX = "p2ws-nr-"


def phone_env():
    """The phone's launch environment: the Cloud service it calls, and the test account's
    sign-in (read from the rig's private copy, never logged)."""
    env = json.loads(os.environ.get("PQ_PHONE_ENV", "{}"))
    creds = os.path.expanduser(os.environ.get("PQ_PHONE_CREDS", "~/cmux-next-ios-e2e/newrows/rig/secrets/agent-auth.env"))
    if os.path.exists(creds):
        for line in open(creds):
            if "=" in line:
                k, v = line.strip().split("=", 1)
                # The phone's DEBUG password sign-in (CmuxMobileAuthModel): CMUX_MOBILE_STACK_EMAIL / _PASSWORD.
                env[k.replace("CMUX_UITEST_STACK_", "CMUX_MOBILE_STACK_")] = v.strip('"')
    return env


def launch(j):
    j.sim.launch(pq.BUNDLE, env=phone_env())
    time.sleep(4)


def fresh(j):
    """Each flow starts on the Workspaces list, the app relaunched with its rig environment."""
    launch(j)
    seed = pq.load()["ws_name"]
    for _ in range(14):
        # The list (newest rows first: the seed row can be below the fold).
        if j.sim.find(prefix=seed, kind="Button") or (j.sim.find(ident="workspaces.list") and j.sim.find(ident="workspaces.new")):
            return
        done = [e for e in j.sim.find(kind="Button") if e.label in ("Done", "Not now") and e.frame[1] < 140]
        back = [e for e in j.sim.find(label="Back", kind="Button") if e.frame[1] > 760] or \
               [e for e in j.sim.find(label="Workspaces", kind="Button") if e.frame[1] < 120]
        tabbar = j.sim.find(label="Workspaces", kind="RadioButton")
        if done:
            j.sim.tap_el(done[0])
        elif back:
            j.sim.tap_el(back[0])
        elif tabbar:
            j.sim.tap_el(tabbar[0])
        time.sleep(1.5)
    raise Fail("could not get to the Workspaces list after a relaunch")


def find_row(j, name, tries=12):
    """A Workspaces row, scrolled to: from the top of the list down (rows are newest first and
    load as they scroll in)."""
    j.back_to_list()
    for _ in range(3):
        j.sim.swipe(200, 300, 200, 700, 0.3)
        time.sleep(0.3)
    for _ in range(tries):
        found = [e for e in j.sim.find(prefix=name, kind="Button") if 90 < e.frame[1] < 740]
        if found:
            return found[0]
        j.sim.swipe(200, 640, 200, 300, 0.4)
        time.sleep(0.8)
    raise Fail(f"{name} not on the phone")


def open_ws(j, name):
    j.sim.tap_el(find_row(j, name))
    time.sleep(2.5)


# The shared flows (pq_crows' chat seed, pq_panes) open workspaces through pq_tabs: scroll there too.
t.open_ws = open_ws


def tab(j, name):
    e = j.sim.wait(label=name, kind="RadioButton", timeout=10)
    check(e, f"no {name} tab")
    j.sim.tap_el(e)
    time.sleep(1.5)


def settings_row(j, label, ident=None, tries=10):
    """A Settings row, scrolled to."""
    tab(j, "Settings")
    for _ in range(tries):
        e = (j.sim.find(ident=ident) if ident else []) or j.sim.find(label=label, kind="Button") or j.sim.find(prefix=label, kind="Button")
        e = [x for x in e if 90 < x.frame[1] < 760]
        if e:
            return e[0]
        j.sim.swipe(200, 640, 200, 300, 0.4)
        time.sleep(0.7)
    return None


def labels(j):
    return [e.label for e in j.sim.find() if e.label][:80]


def cli(*args, timeout=60):
    """The rig Mac's bundled `cmux` CLI, as the rig Mac's signed-in account."""
    out = w.mac().cmux(*args, check=False, timeout=timeout, json_out=True)
    return out


# ---------------------------------------------------------------- Cloud side (the account)

def cloud(op, params=None, mutation=False):
    """One automation op as the rig Mac's signed-in account (its `cloud.automation` relay, the
    same Worker the phone calls)."""
    args = ["automation", "--target", "cloud"]
    return cli(*args, op, json.dumps(params or {}))


def automations_on_cloud():
    """The account's Cloud automations as the service lists them (the Mac's CLI)."""
    out = cli("automation", "list", "--target", "cloud")
    if isinstance(out, dict):
        return out.get("automations") or (out.get("value") or {}).get("automations") or []
    return out or []


# ---------------------------------------------------------------- setup

def setup(app_path):
    """One simulator (named in the rig Mac's pairing seed), the app at `app_path`, signed in as the
    test account from its launch environment, the rig Mac picked, a seed workspace."""
    st = pq.load()
    lst = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True).stdout)
    udid = next((d["udid"] for devs in lst["devices"].values() for d in devs if d["name"] == pq.SIM_NAME), None)
    if not udid:
        udid = subprocess.run(["xcrun", "simctl", "create", pq.SIM_NAME, pq.DEVICE, pq.RUNTIME], capture_output=True, text=True).stdout.strip()
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], capture_output=True, timeout=600)
    subprocess.run(["xcrun", "simctl", "uninstall", udid, pq.BUNDLE], capture_output=True)
    subprocess.run(["xcrun", "simctl", "install", udid, app_path], check=True, capture_output=True)
    mac = pq.RemoteMac()
    st.update(udid=udid, app_path=app_path, device_id=mac.device_id(), mac_name=mac.computer_name(),
              ws_name=st.get("ws_name") or f"parity-{time.strftime('%H%M%S')}")
    pq.save(st)
    sim, mac, j = pq.ctx()
    proj = f"{pq.RBASE}/proj"
    pq.rsh(f"mkdir -p {proj} && printf '# parity\\n' > {proj}/README.md")
    if not w.mac_workspace(st["ws_name"]):
        mac.cmux("workspace", "create", "--name", st["ws_name"], "--cwd", pq.rsh(f"cd {proj} && pwd").stdout.strip(), json_out=True)
    launch(j)
    i, _ = j.sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"), dict(contains="Connect your Mac"),
                           dict(label="Workspaces", kind="RadioButton")], timeout=90)
    check(i is not None, f"the test account never signed in from the launch environment: {labels(j)[:20]}")
    j.step("choose_space", "choose_space", "parity", j.s_choose_space)
    j.step("pick_mac", "the rig Mac", "parity", lambda: pq.pick_mac(j))
    return j.results


# ---------------------------------------------------------------- flows

def automations(j, label):
    """Settings → Automations. Before: no such row. After: the account's Cloud automations in the
    Mac's sections; Run Now on one, Pause on it, Delete on another, each read back from the service."""
    out = {"seeded": automations_on_cloud()}
    row = settings_row(j, "Automations", ident="settings.automations", tries=4)
    pq.shot(f"automations-{label}-settings")
    out["row"] = bool(row)
    if label == "before":
        return out
    check(row, "no Automations row in Settings")
    j.sim.tap_el(row)
    time.sleep(3)
    check(j.sim.wait(ident="automations.list", timeout=30) or j.sim.wait(ident="automations.empty", timeout=2),
          f"no automations list: {labels(j)[:30]}")
    pq.shot("automations-after-list")
    names = [a.get("name") for a in out["seeded"] if a.get("name", "").startswith("nr-")]
    check(names, "no nr- automation seeded on the account")
    target = sorted(names)[0]
    e = j.sim.wait(contains=target, timeout=10)
    check(e, f"{target} not listed on the phone")
    j.sim.tap_el(e)
    time.sleep(2)
    pq.shot("automations-after-detail")
    j.sim.tap_q(ident="automations.run", timeout=8)
    time.sleep(3)
    pq.shot("automations-after-run")
    out["run_note"] = [x.label for x in j.sim.find(ident="automations.started")]
    j.sim.tap_q(ident="automations.toggle", timeout=8)
    time.sleep(3)
    after = {a.get("name"): a for a in automations_on_cloud()}
    out["paused_on_cloud"] = after.get(target, {}).get("enabled") is False
    pq.shot("automations-after-paused")
    runs = cli("automation", "runs", "--target", "cloud")
    out["runs_on_cloud"] = runs
    if len(names) > 1:
        victim = sorted(names)[1]
        r.dismiss(j)
        back = [x for x in j.sim.find(label="Automations", kind="Button") if x.frame[1] < 120] or \
               [x for x in j.sim.find(label="Back", kind="Button") if x.frame[1] < 120]
        if back:
            j.sim.tap_el(back[0]); time.sleep(1.5)
        v = j.sim.wait(contains=victim, timeout=8)
        check(v, f"{victim} not listed")
        x, y = v.center
        j.sim.long_press(x, y, 1.2)
        time.sleep(1.2)
        j.sim.tap_q(ident="automations.delete", timeout=6)
        time.sleep(1)
        pq.shot("automations-after-delete-ask")
        j.sim.tap_q(ident="automations.delete.confirm", timeout=6)
        time.sleep(3)
        out["deleted_on_cloud"] = victim not in {a.get("name") for a in automations_on_cloud()}
        pq.shot("automations-after-deleted")
    return out


def artifacts(j, label):
    """Settings → Artifacts. Before: no such row. After: the synced tree, a file's preview, its History."""
    row = settings_row(j, "Artifacts", ident="settings.artifacts", tries=4)
    pq.shot(f"artifacts-{label}-settings")
    out = {"row": bool(row)}
    if label == "before":
        return out
    check(row, "no Artifacts row in Settings")
    j.sim.tap_el(row)
    time.sleep(4)
    pq.shot("artifacts-after-tree")
    out["tree"] = labels(j)
    entries = [e for e in j.sim.find() if (e.ident or "").startswith("artifacts.synced.entry.")]
    out["entries"] = [e.ident for e in entries]
    failed = j.sim.find(ident="artifacts.synced.failed")
    out["failed"] = [e.label for e in failed]
    if not entries:
        return out
    # Into folders until a file.
    for _ in range(4):
        files = [e for e in entries if "." in (e.ident or "").rsplit(".entry.", 1)[-1]]
        pick = files[0] if files else entries[0]
        j.sim.tap_el(pick)
        time.sleep(3)
        if j.sim.find(ident="artifacts.synced.file") or files:
            break
        entries = [e for e in j.sim.find() if (e.ident or "").startswith("artifacts.synced.entry.")]
    pq.shot("artifacts-after-file")
    out["file"] = labels(j)[:30]
    hist = j.sim.find(ident="artifacts.synced.fileHistory") or j.sim.find(ident="artifacts.synced.history")
    if hist:
        j.sim.tap_el(hist[0])
        time.sleep(3)
        pq.shot("artifacts-after-history")
        out["history"] = labels(j)[:30]
    return out


def home_hide(j, label):
    """Home: a conversation's long-press menu. After: Delete Conversation from List asks, then
    the row leaves the list; Show 1 Hidden Conversation brings it back."""
    tab(j, "Home")
    time.sleep(3)
    # A conversation of the Mac's Home list (the Mac Chief's own row when it is the only one).
    rows = [e for e in j.sim.find() if (e.ident or "").startswith("home.row.") and e.kind == "Button"] or \
        [e for e in j.sim.find(ident="home.chief.mac") if e.kind == "Button"]
    out = {"rows": [e.label for e in rows]}
    check(rows, f"no Home conversation rows: {labels(j)[:20]}")
    target = rows[0]
    out["target"] = target.label
    x, y = target.center
    j.sim.long_press(x, y, 1.2)
    time.sleep(1.2)
    pq.shot(f"home-{label}-menu")
    out["menu"] = [e.label for e in j.sim.find(kind="Button") if e.label][:20]
    if label == "before":
        r.dismiss(j)
        return out
    j.sim.tap_q(ident="home.row.delete", timeout=6)
    time.sleep(1)
    pq.shot("home-after-ask")
    j.sim.tap_q(ident="home.delete.confirm", timeout=6)
    time.sleep(2)
    out["gone"] = not j.sim.find(ident=target.ident)
    pq.shot("home-after-hidden")
    show = j.sim.wait(ident="home.showHidden", timeout=6)
    out["show_hidden"] = show.label if show else None
    if show:
        j.sim.tap_el(show)
        time.sleep(2)
        out["back"] = bool(j.sim.find(ident=target.ident))
        pq.shot("home-after-shown")
    return out


NEXT_PROMPT = ("Reply with exactly these three lines and nothing else:\n"
               "All done.\n[taste] Which icon should the sidebar use?\n- Folder\n- Stack")


def nextstep(j, label):
    """A phone-started chat answers with a tagged ask. Before: the ask is plain text. After: a
    next-step card; tapping Stack sends `Stack` as the next prompt (acpmux records it)."""
    st = c.chat_seed(j, key="nr_chat", turns=("ONE",))
    c.open_chat(j, st)
    c.ask(j, NEXT_PROMPT, "Which icon", timeout=240)
    c.wait_idle(st["session"])
    time.sleep(3)
    pq.shot(f"nextstep-{label}-card")
    card = j.sim.find(ident="agentChat.nextStep")
    out = {"card": bool(card), "session": st["session"]}
    if label == "before" or not card:
        return out
    j.sim.tap_q(label="Stack", kind="Button", timeout=6)
    time.sleep(2)
    def answered():
        said = [x["text"] for x in c.prompts(st["session"])]
        return said if said and said[-1] == "Stack" else None
    out["prompts"], _ = t.until(answered, timeout=60, what="acpmux to record the answer")
    c.wait_idle(st["session"])
    time.sleep(2)
    out["folded"] = [x.label for x in j.sim.find(ident="agentChat.nextStep.answer")]
    pq.shot("nextstep-after-answered")
    return out


def continue_(j, label):
    """A turn that did work fails (the Mac ends its agent mid-turn). Before: Retry. After: the
    card leads with Continue; a tap sends acpmux's turn retry and the chat goes on."""
    st = c.chat_seed(j, key="nr_cont", turns=("ONE",))
    c.open_chat(j, st)
    c.type_in_composer(j, "Count from 1 to 400, one number per line, slowly, then say DONE.")
    c.send(j)
    c.wait_text(j, "12", timeout=180)
    # The failure: the agent process ends under the turn (rig fault, on the Mac).
    out = {"session": st["session"]}
    killed = pq.rsh("for p in $(pgrep -f '@anthropic-ai/claude-code|claude-agent-acp|claude --'); do "
                    "ps -o command= -p $p | grep -q newrows && kill -9 $p && echo $p; done").stdout.split()
    out["killed"] = killed
    lead = j.sim.wait(ident="agentChat.failure.lead", timeout=120)
    pq.shot(f"continue-{label}-card")
    out["lead"] = lead.label if lead else None
    if label == "before" or not lead:
        return out
    j.sim.tap_el(lead)
    time.sleep(5)
    pq.shot("continue-after-tapped")
    events = c.events(st["session"])
    out["retried"] = any(e.get("kind") in ("turn_retry", "turn_retried", "retry") or "retry" in json.dumps(e)[:400] for e in events[-20:])
    return out


def newchaton(j, label):
    """Workspaces → New Workspace (hold). After: New Agent Chat on… › this Mac › a folder starts a
    chat there (acpmux `session/new` in that folder) in a new workspace."""
    before = {s["sessionId"] for s in c.sessions()}
    e = j.sim.wait(ident="workspaces.new", timeout=10)
    check(e, "no New Workspace button")
    x, y = e.center
    j.sim.long_press(x, y, 1.0)
    time.sleep(1.5)
    pq.shot(f"newchaton-{label}-menu")
    out = {"menu": [x.label for x in j.sim.find(kind="Button") if x.label][:30]}
    on = j.sim.find(ident="workspaces.newAgentChatOn")
    out["offered"] = bool(on)
    if label == "before" or not on:
        r.dismiss(j)
        return out
    j.sim.tap_el(on[0]); time.sleep(1.2)
    macs = [x for x in j.sim.find() if (x.ident or "").startswith("workspaces.newAgentChatOn.") and x.ident.count(".") == 2]
    check(macs, "no Mac under New Agent Chat on…")
    j.sim.tap_el(macs[0]); time.sleep(1.2)
    pq.shot("newchaton-after-folders")
    folders = [x for x in j.sim.find() if (x.ident or "").startswith("workspaces.newAgentChatOn.") and x.ident.count(".") >= 3]
    check(folders, "no folder under the Mac")
    out["folder"] = folders[0].label
    j.sim.tap_el(folders[0])
    pq.wait_opened(j, timeout=120)
    def made():
        return [s for s in c.sessions() if s["sessionId"] not in before] or None
    out["sessions"], _ = t.until(made, timeout=90, what="the new chat on the Mac's acpmux")
    pq.shot("newchaton-after-chat")
    return out


def moves(j, label):
    """A workspace row's menu › Move. After: Move Workspace Above… › the row at the top: the
    bottom row of the three goes right above it, on the Mac (its sidebar order)."""
    names = [f"{PREFIX}a", f"{PREFIX}b", f"{PREFIX}c"]
    w.make_workspaces(names)
    order0 = [n for n in w.mac_order() if n in names]
    mover, target = order0[-1], order0[0]
    w.row_menu(j, mover)
    if j.sim.wait(label="Move", timeout=4):
        w.menu_item(j, "Move")
    pq.shot(f"moves-{label}-menu")
    out = {"start": order0, "mover": mover, "target": target,
           "menu": [x.label for x in j.sim.find(kind="Button") if x.label and x.label.startswith("Move")]}
    if label == "before" or not j.sim.find(label="Move Workspace Above…"):
        r.dismiss(j)
        return out
    w.menu_item(j, "Move Workspace Above…")
    pq.shot("moves-after-targets")
    w.menu_item(j, target)
    out["mac"] = w.wait_mac(lambda: (lambda o: o if o.index(mover) == o.index(target) - 1 else None)(
        [n for n in w.mac_order() if n in names]), "the move on the Mac", timeout=20)
    time.sleep(1.5)
    pq.shot("moves-after-moved")
    return out


def reveal(j, label):
    """A workspace's page menu. After: Reveal in Workspaces List goes back to the list, the row
    scrolled to and flashed."""
    names = [f"{PREFIX}r{i:02d}" for i in range(14)]
    w.make_workspaces(names)
    # The oldest of them, far down the list (newest first): opened after a scroll to it.
    target = names[0]
    row = find_row(j, target)
    check(row, f"{target} not on the phone")
    j.sim.tap_el(row)
    time.sleep(2.5)
    labels_ = p.open_page_menu(j)
    pq.shot(f"reveal-{label}-menu")
    out = {"menu": labels_}
    if label == "before" or "Reveal in Workspaces List" not in labels_:
        p.close_menu(j)
        return out
    p.tap_row(j, "Reveal in Workspaces List")
    time.sleep(0.9)
    pq.shot("reveal-after-flash")
    out["flash"] = bool(j.sim.find(ident="workspaces.revealed"))
    row = j.sim.find(prefix=target, kind="Button")
    out["row_visible"] = bool(row) and 90 < row[0].frame[1] < 760
    return out


def compact(j, label):
    """Settings → Compact workspace list. After: on, each workspace row is one line."""
    row = settings_row(j, "Compact workspace list", ident="settings.compactWorkspaceList", tries=4)
    pq.shot(f"compact-{label}-settings")
    out = {"row": bool(row)}
    if label == "before" or not row:
        return out
    tab(j, "Workspaces")
    pq.shot("compact-after-off")
    h0 = [e.frame[3] for e in j.sim.find(kind="Button") if (e.ident or "").startswith("workspace.row.")]
    row = settings_row(j, "Compact workspace list", ident="settings.compactWorkspaceList", tries=4)
    j.sim.tap_el(row); time.sleep(1)
    tab(j, "Workspaces")
    time.sleep(1.5)
    pq.shot("compact-after-on")
    h1 = [e.frame[3] for e in j.sim.find(kind="Button") if (e.ident or "").startswith("workspace.row.")]
    out.update(heights_off=h0[:6], heights_on=h1[:6])
    row = settings_row(j, "Compact workspace list", ident="settings.compactWorkspaceList", tries=4)
    j.sim.tap_el(row); time.sleep(1)
    return out


def queueing(j, label):
    """A chat's page menu. After: Turn Off Prompt Queueing; a message sent while the agent works
    then steers the turn (acpmux records it with `steer`)."""
    st = c.chat_seed(j, key="nr_chat", turns=("ONE",))
    c.open_chat(j, st)
    labels_ = p.open_page_menu(j)
    pq.shot(f"queueing-{label}-menu")
    out = {"menu": labels_}
    if label == "before" or "Turn Off Prompt Queueing" not in labels_:
        p.close_menu(j)
        return out
    p.tap_row(j, "Turn Off Prompt Queueing")
    c.type_in_composer(j, "Count from 1 to 200, one number per line, then say DONE.")
    c.send(j)
    c.wait_text(j, "5", timeout=180)
    c.type_in_composer(j, "Stop counting and reply STEERED.")
    c.send(j)
    time.sleep(3)
    pq.shot("queueing-after-steered")
    out["steer_records"] = [e for e in c.events(st["session"])[-40:] if "steer" in json.dumps(e)][:4]
    c.wait_idle(st["session"])
    labels2 = p.open_page_menu(j)
    out["menu_after"] = [x for x in labels2 if "Queueing" in x]
    if "Turn On Prompt Queueing" in labels2:
        p.tap_row(j, "Turn On Prompt Queueing")
    else:
        p.close_menu(j)
    return out


def menus(j, label):
    """Settings → Long-Press Menus. After: Rename off; a workspace row's menu has no Rename; on again."""
    row = settings_row(j, "Long-Press Menus", ident="settings.longPressMenus", tries=4)
    pq.shot(f"menus-{label}-settings")
    out = {"row": bool(row)}
    if label == "before" or not row:
        return out
    j.sim.tap_el(row); time.sleep(1.5)
    pq.shot("menus-after-page")
    j.sim.tap_q(ident="settings.menus.workspaceRow.rename", timeout=6)
    time.sleep(0.8)
    pq.shot("menus-after-rename-off")
    seed = pq.load()["ws_name"]
    tab(j, "Workspaces")
    w.row_menu(j, seed)
    out["menu_without"] = [x.label for x in j.sim.find(kind="Button") if x.label][:30]
    pq.shot("menus-after-row-menu")
    r.dismiss(j)
    row = settings_row(j, "Long-Press Menus", ident="settings.longPressMenus", tries=4)
    j.sim.tap_el(row); time.sleep(1.5)
    j.sim.tap_q(ident="settings.menus.reset", timeout=6)
    return out


def help_logs(j, label):
    """Settings → About. After: Troubleshooting and Support, Discord, X and GitHub rows, and Copy
    Logs puts this app's log on the clipboard (read back with simctl pbpaste)."""
    tab(j, "Settings")
    for _ in range(8):
        j.sim.swipe(200, 640, 200, 250, 0.3)
        time.sleep(0.4)
    pq.shot(f"help-{label}-about")
    out = {"rows": [x.label for x in j.sim.find(kind="Button") if x.label][-14:]}
    copy = j.sim.find(ident="settings.copyLogs")
    if label == "before" or not copy:
        return out
    subprocess.run(["xcrun", "simctl", "pbcopy", pq.load()["udid"]], input=b"", capture_output=True)
    j.sim.tap_el(copy[0])
    time.sleep(4)
    pasted = subprocess.run(["xcrun", "simctl", "pbpaste", pq.load()["udid"]], capture_output=True, text=True).stdout
    out["clipboard_head"] = pasted.splitlines()[:2]
    out["clipboard_lines"] = len(pasted.splitlines())
    pq.shot("help-after-copied")
    return out


def github(j, label):
    """Settings → Cloud → Connect GitHub. After: its state from the account (`integration.list`)."""
    row = settings_row(j, "Connect GitHub", ident="settings.connectGitHub", tries=4)
    time.sleep(3)
    pq.shot(f"github-{label}-settings")
    out = {"row": bool(row), "value": row.value if row else None, "label": row.label if row else None}
    return out


def forkcolumn(j, label):
    """A chat tab on the Panes page › Fork Conversation. After: In a New Column; the Mac shows the
    copy in a new column (`move-tab-to-column`)."""
    ws, key, name = p.seed("nrfork", terminals=1)
    folder = pq.rsh(f"cd {t.PROJ} && pwd -P").stdout.strip()
    r.acpmux("acp.trust.set", {"cwd": folder, "level": "trusted"})
    sid = p.start_chat(folder, "Reply with the single word PONG.")
    pane = t.ws_tabs(ws)[0][0]
    host = pq.rsh("ps eww -o command -p $(pgrep -f 'newrows.*Contents/Resources/bin/cmux-mobile-host' | head -1) "
                  "| tr ' ' '\\n' | sed -n 's/^CMUX_MOBILE_AGENT_TAB_HOST=//p'").stdout.strip()
    check(host, "the rig Mac's agent tab host")
    t.mac_raw({"cmd": "new-conversation-tab", "pane": pane, "agent_session": {"host": host, "harness": "claude", "session": sid}})
    out = {"start": p.mac_layout(key)}
    t.open_ws(j, name)
    p.open_panes(j)
    pq.shot(f"forkcolumn-{label}-panes")
    chat = [e for e in j.sim.find() if (e.label or "").startswith(("Claude", "PONG")) and e.kind in ("Button", "Cell", "StaticText")]
    out["panes_rows"] = [e.label for e in j.sim.find(kind="Button") if e.label][:30]
    if not chat:
        return out
    x, y = chat[0].center
    j.sim.long_press(x, y, 1.2)
    time.sleep(1.2)
    if j.sim.find(label="Fork Conversation"):
        w.menu_item(j, "Fork Conversation")
    pq.shot(f"forkcolumn-{label}-destinations")
    out["destinations"] = [e.label for e in j.sim.find(kind="Button") if e.label][:20]
    if label == "before" or not j.sim.find(label="In a New Column"):
        r.dismiss(j)
        return out
    w.menu_item(j, "In a New Column")
    columns0 = out["start"]["columns"]
    out["forked"] = p.fork_outcome(j, key, lambda lay: lay["columns"] > max(columns0, 1) or len(lay["panes"]) > len(out["start"]["panes"]))
    pq.shot("forkcolumn-after-forked")
    return out


FLOWS = {"automations": automations, "artifacts": artifacts, "home": home_hide, "nextstep": nextstep,
         "continue": continue_, "newchaton": newchaton, "moves": moves, "reveal": reveal, "compact": compact,
         "queueing": queueing, "menus": menus, "help": help_logs, "github": github, "forkcolumn": forkcolumn}


def run(name, label):
    sim, mac, j = pq.ctx()
    fresh(j)
    pq.rec_start(f"{name}-{label}")
    try:
        out = FLOWS[name](j, label)
    finally:
        pq.rec_stop()
    os.makedirs(pq.ART, exist_ok=True)
    json.dump(out, open(os.path.join(pq.ART, f"{name}-{label}.json"), "w"), indent=2, default=str)
    return out
