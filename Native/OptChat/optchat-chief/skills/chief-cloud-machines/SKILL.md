---
name: chief-cloud-machines
description: Use the user's cmux Cloud machines from the Mac with the cmux CLI: list, create (cmux Pro), run commands, use the machine's own cmux, and drive its Linux desktop with cua-driver (open apps, click, type, screenshots). Use when the user asks for a cloud machine, a VM, or a task on a remote desktop or browser.
cmux-managed: true
---

# Cloud machines

The user's cmux Cloud machines are Linux VMs with a 1440x900 desktop
(`DISPLAY=:1`), Chrome, `cua-driver` (computer use for its windows) and the
machine's own `cmux`. You reach them from the Mac through the cmux app's
Cloud actions; the app holds the sign-in and asks the user before anything
that costs money.

Every machine action takes `--target machine:<id>`; without it the app
refuses the run. `cmux action describe "cloud <verb>"` shows a verb's
arguments. With `--json`, an action's fields are under `.result`.

## 1. Find or make a machine

```sh
cmux --json cloud diagnostics | jq '.result.details | fromjson | {signed_in, unavailable, machines: [.machines[] | {id, title, status}]}'
```

That lists every Cloud machine, paused ones too; `id` is the target
(`--target machine:<id>`). `signed_in` false or `unavailable` set means Cloud
cannot work yet: tell the user to sign in to cmux.

- Prefer a running machine that fits. Never pause, resume, resize or kill a
  machine the user did not name.
- To make one: `cmux --json cloud new-machine`. The app shows the user a
  Create card; nothing is made until they click. It answers `.result.machine_id`
  and `.result.target`, or `.result.pending: true` while the server still
  provisions (list the machines again later; never ask for a second machine).
  "declined" means the user said no: stop.
- Cloud machines come with cmux Pro. When a create fails with a reason that
  names cmux Pro, the app shows the user an Upgrade to cmux Pro dialog when a
  cmux window is open. Say once, in one line, what the reason said and that
  the dialog (or `cmux settings upgrade-to-pro`) opens the plans; do not retry,
  and do not mention Pro when Cloud works.

## 2. Run commands

```sh
cmux --json cloud exec --target machine:<id> --command '<shell command>'
```

It answers `.result.exit_code`, `.result.stdout` and `.result.stderr`, and
stops after 25 s. The command runs without a login profile: set
`HOME=/home/cmux` for tools that read it, and use the machine's paths
(`/home/cmux/...`); nothing from this Mac exists there. A `--command` value
cannot start with `--`. Batch probes into one command. For longer work, start
it detached and read its log:
`mkdir -p /home/cmux/.cache/chief; setsid -f sh -c '<cmd> >/home/cmux/.cache/chief/job.log 2>&1'`, then
`cmux --json cloud file-read --target machine:<id> --path /home/cmux/.cache/chief/job.log`.
Files: `cloud files-list`, `file-read` (`text`, or `data_base64` for binary),
`file-write --contents`, `file-mkdir`, `file-stat`. Never copy the user's
credentials to a machine.

The machine has its own `cmux` for its own terminals and workspaces; run it
through exec with its home:
`cmux cloud exec --target machine:<id> --command 'HOME=/home/cmux cmux workspace list'`,
then the same way `cmux terminal list`, `cmux terminal term_… write --text $'...\n'`
and `cmux terminal term_… screen read`. A new terminal there:
`cmux --json cloud new-terminal-on-machine --target machine:<id>`.

## 3. Drive the desktop (computer use)

Install the step helper once per machine (it starts `cua-driver`'s daemon when
it is not running, runs one tool, then saves a screenshot):

```sh
cmux cloud file-mkdir --target machine:<id> --path /home/cmux/.cache/chief
cmux cloud file-write --target machine:<id> --path /home/cmux/.cache/chief/cua.sh --contents "$(cat <<'EOF'
export HOME=/home/cmux
. /etc/cmux/desktop-env.sh
if ! cua-driver status >/dev/null 2>&1; then
  setsid -f cua-driver serve >/dev/null 2>&1 </dev/null
  i=0; while [ "$i" -lt 20 ] && ! cua-driver status >/dev/null 2>&1; do i=$((i+1)); sleep 0.5; done
fi
cua-driver call "$1" "$2" || exit $?
cua-driver call get_desktop_state '{"screenshot_out_file": "/home/cmux/.cache/chief/screen.png"}' >/dev/null
EOF
)"
```

Then one step per exec. Put the command in a quoted heredoc so its JSON needs
no escaping:

```sh
step=$(cat <<'EOF'
sh /home/cmux/.cache/chief/cua.sh launch_app '{"name": "google-chrome-stable", "additional_arguments": ["--new-window", "--start-maximized", "--no-first-run", "--hide-crash-restore-bubble", "https://example.com"]}'
EOF
)
cmux --json cloud exec --target machine:<id> --command "$step"
```

- Tools: `list_windows` (`{}`: pid, `window_id`, title, bounds),
  `launch_app`, `get_window_state` (a window's accessibility elements; click
  by `element_index`), `click`, `type_text`, `press_key`, `hotkey`, `scroll`,
  `zoom`. Before a tool's first use, read its arguments:
  `cua-driver describe <tool>` (after `. /etc/cmux/desktop-env.sh`).
  `cua-driver doctor` explains a failure; a machine without `cua-driver`
  (`command -v cua-driver` fails) is too old: say so.
- Look before you claim. Text results (`list_windows`, `get_window_state`)
  confirm a window or title. To see the screen, bring the screenshot here and
  look at it, and send it to the user when it shows what they asked for:
  `cmux --json cloud file-read --target machine:<id> --path /home/cmux/.cache/chief/screen.png | jq -r '.result.data_base64' | base64 -d > "${TMPDIR:-/tmp}/chief-<id>.png"`.
  Never say something happened on the desktop until a result or a screenshot
  shows it.
- A long desktop task (many steps, a whole flow to test) goes to a coding
  agent on the machine instead: its Codex, Claude Code and OpenCode get
  `cua-driver mcp` as a tool on first launch. Check its sign-in first
  (`HOME=/home/cmux codex login status`, `HOME=/home/cmux claude auth status --text`);
  when it is not signed in, tell the user to sign it in rather than copying
  credentials.
- Use `agent-browser` on the machine for a task that is only web pages,
  `cua-driver` for desktop windows. Close only windows you opened. Leave the
  driver's daemon running; an agent on the machine may use it.
