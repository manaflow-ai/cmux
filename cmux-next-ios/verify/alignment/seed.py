"""Seeds the rig Mac with what the list screens need, through its own cmux CLI.

    python3 seed.py RIG_DIR

Workspaces: two pinned (Pinned section), one titled only with an emoji ("☕"), two groups
("Cloud - iOS" expanded with two workspaces, "CI / CD" collapsed with two), loose ones, and
two acpmux fake-agent chats that ask a permission (Needs You on the phone, Feed rows).
Idempotent: existing names and groups are reused.
"""
import json
import os
import subprocess
import sys

RIG = os.path.abspath(sys.argv[1])


def cli(*args, check=True):
    r = subprocess.run(["python3", "rig_hdr.py", "cli", "--json", *args], cwd=RIG, capture_output=True, text=True, timeout=90)
    if check and r.returncode != 0:
        raise RuntimeError(f"cmux {' '.join(args)}: {(r.stderr or r.stdout).strip()[:300]}")
    out = r.stdout.strip()
    try:
        return json.loads(out) if out else None
    except ValueError:
        return out


def workspaces():
    return {w["name"]: w["id"] for w in cli("workspace", "list") or []}


def ensure(name):
    ws = workspaces()
    if name not in ws:
        cli("workspace", "create", "--name", name)
        ws = workspaces()
    return ws[name]


def groups():
    g = cli("workspace", "group", "list") or []
    if isinstance(g, dict):
        g = g.get("groups") or g.get("items") or []
    return {x.get("name"): x.get("id") for x in g}


def main():
    names = ["api-server", "web-frontend", "docs-site", "ios-app", "sim-runner", "nightly", "release-bot", "☕"]
    ids = {n: ensure(n) for n in names}
    print("workspaces", ids)
    plan = {"Cloud - iOS": (["ios-app", "sim-runner"], False), "CI / CD": (["nightly", "release-bot"], True)}
    for gname, (members, collapse) in plan.items():
        g = groups()
        if gname not in g:
            cli("workspace", "group", "create", "--name", gname, "--color", "blue" if not collapse else "green")
            g = groups()
        for m in members:
            cli("workspace", "group", g[gname], "add", "--workspace", ids[m], check=False)
        cli("workspace", "group", g[gname], "update", "--collapse" if collapse else "--expand", check=False)
    print("groups", groups())
    # Pin/Unpin toggles: pin once per rig (a marker file remembers it).
    marker = os.path.join(RIG, ".seeded-pins")
    for n in () if os.path.exists(marker) else ("api-server", "docs-site"):
        r = subprocess.run(["python3", "rig_hdr.py", "cli", "action", "run", "palette.toggleWorkspacePin", "--target", ids[n], "--wait"],
                           cwd=RIG, capture_output=True, text=True, timeout=60)
        print("pin", n, r.returncode, (r.stdout + r.stderr).strip()[:200])
    open(marker, "w").write("pinned api-server, docs-site\n")
    for text in () if os.path.exists(os.path.join(RIG, "asks.log")) else ("ask: run the test suite", "ask: deploy the docs"):
        subprocess.run(["python3", "rig_hdr.py", "ask", text], cwd=RIG, timeout=60)
    # Needs You: an agent in the workspace reports itself blocked (waiting for a permission).
    for n in ("web-frontend", "sim-runner"):
        terms = cli("terminal", "list", "--workspace", ids[n]) or []
        if terms:
            r = cli("agent", "report", "--terminal", terms[0]["id"], "--state", "blocked", "--source", "hook", check=False)
            print("blocked", n, terms[0]["id"], str(r)[:200])
    print(json.dumps(cli("workspace", "list"), indent=0)[:1500])


if __name__ == "__main__":
    main()
