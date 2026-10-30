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

To show the user a machine's desktop live (they ask to see it, or you start
working on it so they can watch): `cmux cloud open-desktop --target machine:<id>`.
It opens a "<machine> Desktop" workspace whose cmux browser shows the
machine's screen through the app's own Cloud tunnel, with no port opened on
this Mac. Run it once; say it is in the sidebar.

To show the desktop beside the chat instead (Home's right column, or any
browser tab), open its address there:
`http://<machine id, lowercase>.cloud-desktop.localhost:6901/vnc.html?autoconnect=1&resize=scale&reconnect=1`.
The app routes that address through its own Cloud tunnel; it never touches a
port on this Mac. A blank or disconnected desktop page: reload it or run
`cmux cloud open-desktop` again; if it stays dark, tell the user.

Never build your own way into a machine: no `cmux-tui wg hub`, no SSH or
port tunnel, no local port bridge (`127.0.0.1:16901` and the like), no
scripts that start one, and never read or copy the app's WireGuard key or
config. The key lives only in the app's memory, and enrolling another key
for this Mac also takes the app's tunnel away; a second hub knocks
the app's own link off the machine (its terminals and desktop freeze, the
mouse stops answering), and a local port to the desktop hands the machine's
unprotected VNC to every program on this Mac. A note or memory that says
otherwise (a `vmtunnel` folder, `restart.sh`, a 16901 bridge) is out of date:
do not follow it.

## 1. Find or make a machine

```sh
cmux --json cloud list-machines
```

`.result.machines` lists every Cloud machine (paused ones too) with its
`target` (`machine:<id>`, what `--target` takes), `title` and `status`.
`.result.account.signed_in` false means Cloud cannot work yet: tell the user
to sign in to cmux. `.result.loaded` false means the list is still loading:
run it again before deciding there is no machine.

- Prefer a running machine that fits. Never pause, resume, resize or kill a
  machine the user did not name.
- To make one: `cmux --json cloud new-machine`. The app shows the user a
  Create card; nothing is made until they click. It answers `.result.machine_id`
  and `.result.target`, or `.result.pending: true` while the server still
  provisions (list the machines again later; never ask for a second machine).
  "declined" means the user said no: stop.
- Cloud machines come with a paid plan. A create the plan does not allow
  fails with error code `cloud.plan.required`, and its message ends with
  `(plan: pro)` (no plan yet: a free or Go account) or `(plan: max)` (a Pro
  plan's budget, pool or a size only Max has). Do not retry it. Give the user
  a link to pay for that plan in the same reply:
  `cmux --json billing checkout --plan <pro|max> --no-open` answers the Stripe
  Checkout `url` without opening anything (the app may already show an
  Upgrade to cmux Pro dialog; never open a second page on top of it). Say in
  one line what the reason said and what the plan adds (the `paid-plans`
  skill has the prices), give the `url` as a link, and say nothing is charged
  until they pay there. On a `billing.live_off` or `billing_unavailable`
  error give https://cmux.com/pricing instead; on `flow: portal` say the page
  switches their current plan. When they say they paid, check
  `cmux --json billing status` and run the create once more. Do not mention
  plans when Cloud works.

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

Install the step helper once per machine. It starts `cua-driver`'s daemon
when it is not running, runs one tool, then saves a fresh screenshot, and
fails when no screenshot was saved (`cua-driver` exits 0 even then). Make its
folder with exec, which runs as the machine's `cmux` user like the daemon:
`cloud file-mkdir` makes a root-owned folder the daemon cannot write to.

```sh
cmux cloud exec --target machine:<id> --command 'mkdir -p /home/cmux/.cache/chief'
cmux cloud file-write --target machine:<id> --path /home/cmux/.cache/chief/cua.sh --contents "$(cat <<'EOF'
export HOME=/home/cmux
. /etc/cmux/desktop-env.sh
if ! cua-driver status >/dev/null 2>&1; then
  setsid -f cua-driver serve >/dev/null 2>&1 </dev/null
  i=0; while [ "$i" -lt 20 ] && ! cua-driver status >/dev/null 2>&1; do i=$((i+1)); sleep 0.5; done
fi
cua-driver call "$1" "$2" || exit $?
rm -f /home/cmux/.cache/chief/screen.png
cua-driver call get_desktop_state '{"screenshot_out_file": "/home/cmux/.cache/chief/screen.png"}' >/dev/null
test -s /home/cmux/.cache/chief/screen.png || { echo "no screenshot saved: run cua-driver doctor" >&2; exit 1; }
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
- A `click` or `type_text` result can say `"effect": "unverifiable"`: the
  input was sent, so check what changed (a window title, or the screenshot).
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
