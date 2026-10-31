---
name: cmux-cli
description: Use the cmux CLI from a Chief turn or a subagent: find your workspace and pane, open files, pages and terminals beside the chat, notify the person, read the app's version. Use before any `cmux` command you have not run in this chat.
cmux-managed: true
---

# The cmux CLI (tool pack `cmux`)

Shipped by the `cmux` tool pack (plans/cmux-next/chief-toolpacks-DESIGN.md). `chief pack check cmux`
runs `cmux version --json`: the CLI, the app its socket reaches, the channel and the update state.

1. Where you are: `cmux --json identify` (your workspace, `caller.pane`, `beside.pane`).
2. Show things in the column beside the chat, as a new tab, never in the chat's pane:
   `cmux open URL`; `cmux action run file.open --target <beside.pane> --path FILE --where tab`;
   `cmux tab create terminal --pane <beside.pane>`. With no column yet:
   `cmux pane <caller.pane> split --right --viewport-width 0.5`, once.
3. Sidebar groups are the person's: never make one or move a workspace into one unless the person
   asks (then `cmux --json workspace group list`, `cmux workspace group <group> add --workspace <ws_…>`).
   Never close or rename the person's workspaces.
4. `cmux --help` and `cmux <verb> --help` list the rest; every verb takes `--json`.
5. Links in replies: `cmux://workspace/ws_…`, `cmux://pane/pane_…`, `cmux://tab/tab_…`.
