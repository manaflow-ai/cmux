---
name: chief-cloud-machines
description: Use the user's cmux Cloud machines from the Mac with the cmux CLI: list, create (cmux Pro), hand a task to an agent chat there and read its reply (`cmux cloud start-chat`), run commands, use the machine's own cmux, and drive its Linux desktop (open pages, click, type, screenshots) with the cloud_computer tool. Use when the user asks for a cloud machine, a VM, or a task on a remote desktop or browser.
cmux-managed: true
---

# Cloud machines

The user's cmux Cloud machines are Linux VMs with a 1440x900 desktop
(`DISPLAY=:1`), Chrome, `cua-driver` (computer use for its windows) and the
machine's own `cmux`. You reach them from the Mac through the cmux app's
Cloud actions; the app holds the sign-in and asks the user before anything
that costs money.

The cmux MCP server has tools for the common steps; load them with
ToolSearch `cloud_`: `cloud_machines` (list), `cloud_chat_start`,
`cloud_chat_send`, `cloud_chat_status` (agent chats there), `cloud_computer`
(the desktop) and `cloud_computer_control` (who drives it). Each runs the same
code as its command below; use whichever you have.

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

## Run a task as an agent chat on a Cloud machine

For subagents, `spawn` picks a machine automatically; `place` accepts here/local/mac, cloud (also cloud:small|medium|large), or a paired machine name, while optional harness routing stays off by default.

To hand a task to a coding agent on a Cloud machine and get its answer, use
one command:

```sh
cmux --json cloud start-chat --prompt '<the task>' --wait
```

It starts a chat (`--agent claude` by default, or `codex`) on a new small
machine of its own (or `--name <name>`, or `--target machine:<id>` for a
machine the user named), sends the prompt, waits for the turn to end and
answers `.reply` with `.machine_id`, `.session_id` and `.tab_id`. The chat is
a tab in that machine's workspace, so the user can open it. `--cwd <folder
on the machine>` picks the folder; `--timeout <seconds>` bounds the wait
(default 900). The app first asks the user with a card (Start, Not now);
nothing starts until they click Start, and a refusal says so.

The answer's `.follow_up` holds the commands for that chat (the tools take
the same `machine` and `session`): `send` (`cmux cloud chat send --target
machine:<id> --session <session_id> --prompt '<next prompt>'`, or
`cloud_chat_send`; it answers `after`), `status` (`cmux cloud chat status ...
--after <after> --wait 20`, or `cloud_chat_status` with `wait_s`: `.state` is
`starting`, `running`, `permission_waiting` (the agent asks the user in the
chat's tab: tell them), `ended` with `.reply`, or `failed`) and `last` (the
newest reply). Run `status` again while it is `starting` or `running`. On an
error, read `.code`: `cloud.signed_out` (tell the user to sign in to cmux),
`cloud.start_pending` (the machine is still starting: run `.details.again`
later), `chat.permission_waiting` (tell the user), `chat.wait_timeout` (still
working: wait on with `.details.answer.follow_up.status`).

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

Use `cloud_computer` (or `cmux cloud computer <op> --target machine:<id>`;
`cmux cloud computer --help` lists the flags). Without `machine` it uses the
machine attached to you as your computer. One op per call:

- `screenshot`: the screen as an image (the command saves a PNG, `--out FILE`).
  Look at it before and after you act, and send it to the user when it shows
  what they asked for.
- `list_windows`: the desktop's windows (pid, `window_id`, title, bounds).
- `open_url` with `url`: opens it in a new Chrome window.
- `click` (`x`, `y`, `button`), `move`, `drag` (`x`, `y`, `to_x`, `to_y`),
  `scroll` (`x`, `y`, `direction`, `amount`), `type` (`text`), `key`
  (`keys`: `Return`, `ctrl+l`, `shift+Tab`). Coordinates are screen pixels of
  the 1440x900 screenshot.
- Never say something happened on the desktop until a result or a
  screenshot shows it. A `"effect": "unverifiable"` result means the input
  was sent: check the screenshot.
- The user can take over the desktop from your profile's Computer tab. While
  they hold it, input ops fail with `computer.human_has_control` (screenshots
  still work): stop, say you are waiting for them, and continue after they
  give it back (`cloud_computer_control` `status`). When a step needs the
  user (a sign-in, a password, a payment, a captcha), call
  `cloud_computer_control` `request_human` with a short `reason` and tell
  them; never type a password or card number yourself.
- `computer.failed` says what `cua-driver` reported; a machine without
  `cua-driver` is too old: say so. For anything the ops do not cover, run
  `cua-driver` through `cloud exec` after `. /etc/cmux/desktop-env.sh`
  (`cua-driver describe <tool>` lists a tool's arguments).
- A long desktop task (many steps, a whole flow to test) goes to a coding
  agent on the machine instead: its Codex, Claude Code and OpenCode get
  `cua-driver mcp` as a tool on first launch. Check its sign-in first
  (`HOME=/home/cmux codex login status`, `HOME=/home/cmux claude auth status --text`);
  when it is not signed in, tell the user to sign it in rather than copying
  credentials.
- Use `agent-browser` on the machine for a task that is only web pages,
  `cua-driver` for desktop windows. Close only windows you opened. Leave the
  driver's daemon running; an agent on the machine may use it.
