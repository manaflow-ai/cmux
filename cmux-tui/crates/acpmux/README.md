# acpmux

tmux for ACP agents. A Rust daemon keeps [Agent Client Protocol](https://agentclientprotocol.com)
agents (Codex, Claude Code, Gemini, OpenCode, Pi, ...) alive as named sessions, records every
wire message, and lets any number of clients attach, prompt, steer, cancel, fork, and change
model or mode. It speaks plain ACP to its clients plus a small `_acpmux/*` extension, so the
CLI, the TUI, a web dashboard, or a Cloudflare Durable Object all use the same protocol.

acpmux never makes outbound calls to a control plane. Something that wants to control it
connects to it.

## Build

```sh
cd acpmux
cargo build --release
rm -f ~/.local/bin/acpmux && cp target/release/acpmux ~/.local/bin/
```

Remove the old binary first. On macOS, copying over an existing binary in place keeps the
inode, the kernel keeps the stale code-signature cache, and the new binary dies with signal 9.

## Quick start

```sh
acpmux                               # that is it: starts the daemon if needed, opens the TUI
```

`Ctrl-t` opens a new session tab at the top of the sidebar with an empty transcript and the
cursor in the editor, like opencode's `Ctrl-x n`. It inherits the agent, directory, and policy
of the session you were on; change them with `/agent NAME`, `/cwd PATH`, `/policy P` before
sending. The first Enter creates the session with that message. Esc on an empty draft discards
it. `/form` opens the older field-by-field form instead. The bottom line of the TUI shows
the web dashboard URL.

```sh
acpmux web                           # print the dashboard URL and open it in the browser
acpmux new -a codex -n backend-review   # scripted: create a session and open the TUI on it
acpmux send backend-review "inspect the failing tests"
acpmux ls
acpmux attach backend-review         # TUI on one session; Ctrl-q leaves, the agent keeps running
```

The daemon starts on demand, like the tmux server. `acpmux daemon` runs it in the foreground.

## Web dashboard

The daemon serves a dashboard on the same port as its WebSocket, by default
`http://127.0.0.1:47811/?token=…`. The token is generated on first run and saved in
`config.json`; `acpmux web` prints the full link. The dashboard lists every session, local and
peered, streams transcripts live, sends messages, steers, cancels, answers permission
requests, and changes model, mode, and any adapter option. To reach it from another machine,
set `websocket.listen` to a non-loopback address and put a tunnel or firewall in front.

## CLI

Five everyday commands, three groups for the rest:

| Command | What it does |
| --- | --- |
| `acpmux` | Open the TUI. Starts the daemon if needed. |
| `new [-a agent] [-n name] [--cwd dir] [--policy p] [prompt]` | Create a session. Opens the TUI unless `-d`. |
| `send NAME "text" [--steer] [--no-wait] [-q]` | Prompt and stream the reply. |
| `ls` | Sessions on every host, as `host/name` for remote ones. |
| `attach [NAME] [--plain]` | TUI on one session, or a plain text stream. |
| `web [--no-open]` | Print the dashboard URL and open it. |
| `host add NAME URL` / `host ls` / `host rm NAME` | Remote daemons. URL is `ssh://host`, `ws://…`, or `wss://…`. |
| `session info\|cancel\|stop\|rename\|fork\|set\|allow\|deny\|export\|import\|tail NAME …` | Everything about one session. |
| `daemon run\|status\|shutdown\|config\|agents` | The daemon itself. |

The older flat spellings (`acpmux kill NAME`, `acpmux peer add …`, `acpmux status`) still
work but are hidden from help.

`--json` on any command prints the raw response.

## Orchestrating agents from scripts

Every command takes `--json` before it for machine output; errors then go to stderr as one
`{"error": {"code", "detail", "message", "sessionId", "retryable"}}` object and nothing is
printed on stdout. Exit codes are stable: 0 ok, 1 runtime or agent error, 2 usage, 3 timeout,
4 no such session, 5 every permission in the turn was denied, 130 interrupted.

```
acpmux run -a codex --cwd ~/proj "fix the failing test"      # new session, send, print only the reply
acpmux exec -a claude "one-shot"                              # same, and the session is deleted afterwards
acpmux --json run -a claude --policy approve-all "..."       # {"sessionId","name","reply","stopReason","permissions",…}
acpmux ensure NAME -a codex --cwd DIR                         # the session if it exists, else create it
acpmux send NAME --no-wait "..."                              # queue and return; prints "queued behind 1 running turn"
acpmux send NAME --timeout 120 --on-permission deny|fail "…"  # cancel after 120 s (exit 3); answer prompts without a human
acpmux wait                                                   # until any session on any host resolves (turn ended or needs a permission)
acpmux wait NAME… --until ready|permission|closed|done|running [--all] [--timeout 300] [--print] [--notify]
acpmux wait NAME --match "tests pass" | --regex "pass(ed)?"   # until the agent's output contains it
acpmux last NAME [-n 3]                                       # last reply text
acpmux history NAME                                           # one line per turn: status, wall time, tools, tokens, prompt
acpmux pending                                                # every pending permission, with the option ids to answer it
acpmux session allow NAME [OPTION] | acpmux session deny NAME
acpmux session rules NAME '{"autoDeny": ["rm -rf"], "ask": ["execute"], "default": "approve"}'
acpmux session tag NAME task=review --ttl 3600; acpmux ls --tag task=review
acpmux ls --status running | --pending                        # filters; --json for the full records
acpmux session tail NAME --since <sessionId>:<seq> --follow   # raw events as JSON lines; a cursor past the log is exit 2
acpmux compare -a claude -a codex "prompt"                    # one temporary session per harness, run one after another
acpmux skill                                                  # the agent skill file; acpmux daemon schema prints the RPC surface
```

Waits run in the daemon: a per-session `stateSeq` bumps on every status, permission and
turn change and the wait subscribes to hub events, so nothing is missed between the check
and the subscribe. `done` means a turn ended while no client was attached. `send` reports
`prompt_stalled` (exit 1) when the agent produces nothing for 30 s (`--stall 0` disables); the
turn keeps running. `run --retries N` retries only agent-internal errors that produced nothing.

Agents spawned by acpmux get `ACPMUX_ENV=1`, `ACPMUX_SESSION_ID`, `ACPMUX_SESSION_NAME` and
`ACPMUX_SOCKET`, and `@` names that session (`acpmux last @`), so an agent can drive its own
session and siblings. The event log carries `turn_started` and `turn_result`
(`completed|cancelled|failed`); a daemon that restarts mid-turn writes
`turn_result failed outcome_unknown` so nobody replays a prompt that may have run. A
`notifyCommand` in the config runs on a permission request and on a turn that ends
unattended, with `ACPMUX_EVENT`, `ACPMUX_SESSION_NAME` and `ACPMUX_TEXT` set.

## TUI

The TUI shares cmux-tui's chrome: the same 256-color palette for light and dark terminals, a
single-rule sidebar with two-line rows, a status bar with an active chip, bordered dialogs with
`[ Cancel esc ]  [ OK ⏎ ]` buttons, and the same scrollbar (`▕` thumb, `▐` while dragged,
invisible track, only drawn when rows overflow). Every dialog (help, pickers, permission
requests, forms, confirms) is one component (`src/tui/dialog.rs`): a fixed header, a body that
scrolls with the wheel, PgUp/PgDn, Home/End, track click or thumb drag, and a `N-M/T` counter
in the footer when rows overflow. Set `ACPMUX_THEME=light` or `dark` to override the
`COLORFGBG` guess.

The composer follows Claude Code's shape: a rule, `❯ ` and the message (wrapping under the
prompt, growing to six rows), a rule, then one row of clickable settings: `⏵⏵ mode`, model,
`◉ effort`, permissions, directory, and `? keys · / commands` on the right. Each chip opens its
picker. The transcript title shows only the session name, its state and token usage. The
status bar shows hosts (click one to filter the sidebar), the last message, and a
`web dashboard ↗` link. The sidebar starts with `+ new session` and ends with `+ add host`.

Sidebar rows follow cmux rails: the current row is filled and carries a `▎` rail glyph, an
unread `•` marks sessions that finished a turn (green), wait for a permission (yellow) or
failed (red) while you were elsewhere. The transcript pane has focus when its title is highlighted; there
j/k, u/d, g/G scroll it. Errors are red rows in the transcript (or under a draft) and a red
status-bar message with a `[copy]` button.

Model pickers list every model a harness reports. At start the daemon probes each ACP harness
once (spawn, `initialize`, `session/new`, read the list, kill) so Codex, OpenCode and Gemini
show their catalogs before any session exists; Claude uses a fixed alias table.

```
Enter        send prompt        Ctrl-s   steer, or queue when the agent cannot steer
Ctrl-t / n   new session tab    Ctrl-x   cancel turn
Cmd-Ctrl-h/j/k/l  move focus like cmux panes: h sidebar, l content, k transcript, j composer
                  (Alt-h/j/k/l on terminals that do not deliver Cmd)
Tab          focus sidebar (j/k, x stop, f fork, r rename); Esc or Enter back
Ctrl-n/p     next / prev line in the composer (history at the ends); next / prev session in the sidebar
Alt-s        hide / show the sidebar (`:sidebar`); Alt-h shows it again
Alt-←/→      narrow / widen the sidebar (or drag its rule; the transcript keeps 40 columns)
Ctrl-l       pick model         Ctrl-o   pick mode        Alt-e     pick thinking effort
/            command palette    ?        help             Esc       interrupt the running turn
/set KEY     pick any option    /set KEY=VALUE            Ctrl-Shift-p / Cmd-k also open the palette
wheel PgUp/PgDn scroll          Home/End top / follow the bottom
y / n / 1-9  answer permission  Ctrl-q   quit (agents keep running)
```

The message editor is a real editor: cursor anywhere, Left/Right, Home/End, Ctrl-a/Ctrl-e,
Alt-b/Alt-f or Alt-Left/Alt-Right by word, Ctrl-w and Alt-Backspace delete a word back, Alt-d
forward, Ctrl-k to end of line, Ctrl-u to start of line, Ctrl-d or Delete forward, Ctrl-z undo.
Newline with Ctrl-j, Shift-Enter, or a trailing `\` then Enter. Up and Down move across lines;
at the top or bottom they recall sent messages. Paste inserts at the cursor. The box grows to
eight rows and scrolls inside after that; click to place the cursor.

The row above the transcript is a set of clickable chips: `model`, `mode`, `perms`, `thinking`,
and `dir`. Click one to change it. Model lists every harness on every host and forks into a new
session tab when you pick a different harness. Mode, permissions, and thinking apply to the
running session at once; thinking shows only for harnesses that expose an effort setting, which
today is Codex. Directory opens a dialog: on a draft it just changes, on a running session it
opens a new session tab in that directory, since an agent cannot move mid-session.

Hosts sit in the bottom-left of the status bar as chips: `● mac  ● lawbook  ○ box` with a
green dot when the tunnel is up. Click a chip to show only that host's sessions; `Ctrl-t` and
`[+ new]` then create on that host. Click the chip again to show everything. `[+ host]` opens a
one-field dialog: type what you would type after `ssh`, press Enter, and acpmux opens the
tunnel and reads the remote token itself.

Mouse: click a sidebar row to switch, wheel over the transcript to scroll (the viewport stays
put while output streams until you press End or scroll back down), click the scrollbar track to
jump or drag its thumb. Drag in the transcript to select text; releasing copies it to the host
clipboard over OSC 52 and shows a `Copied` toast. Double-click selects a word, triple-click a
line, and dragging extends by word or line. Typing clears the selection.

Commands start with `/`. Press `/` (or Ctrl-Shift-p, Cmd-k) for the palette: every action
with its keys, filtered as you type. Enter runs the highlighted one; an action that needs
arguments opens the command line with `/name ` typed, and typing `rename foo` straight into
the palette runs it. The full list is `src/tui/actions.rs`, one table that also drives the
help dialog and the key chords: `/new`, `/form`, `/rename NAME`, `/fork [NAME]`, `/stop`,
`/delete`, `/model [ID]`, `/mode [ID]`, `/effort [LEVEL]`, `/policy [P]`, `/cwd [PATH]`,
`/agent NAME`, `/set KEY[=VALUE]`, `/thoughts`, `/host add NAME URL`, `/export`, `/import`,
`/web`, `/quit`.

Thinking effort: Claude Code (`--effort` at spawn, live `apply_flag_settings`), the Zed
Claude adapter (`effort`) and Codex (`reasoning_effort`, up to `ultra`) all expose it. acpmux
calls it `effort` everywhere and maps the name onto the harness's own option, so
`acpmux new --effort high`, `acpmux session set NAME effort=low`, `/effort max`, Alt-e and
the `thinking` chip all work on any of them. OpenCode and Gemini do not expose one over ACP.
Assistant text renders as markdown (pulldown-cmark): headings, emphasis, inline code,
links, nested lists, quotes, rules, simple tables, and fenced code blocks on a shaded
background with syntect highlighting when the language is known. Every row starts after a
two-column gutter (`❯` for you, `▸`/`▾` for collapsibles), so text lines up down the page.
Your messages look like Codex's: a tinted full-width band with `› ` before the text. The
transcript is a hierarchy of collapsibles, each toggled by a click: the whole turn (click
your message; collapsed it shows the first line and `· 3 tool calls · 1 reply`), a run of
consecutive tool calls (`▾ 3 tool calls · Read, Bash, Edit`), one tool call (`▸ ✓ title  kind
first line of output`), and one thought. Turns and groups start open, details closed. The
thought being streamed stays open; `/thoughts` opens them all. Right-click a row for
Expand/Collapse everything, Copy message, Copy row, and Open link.

Right-click works everywhere: a sidebar session (rename, fork, new session in its
directory, export, copy id, open in web, stop, delete), a draft (harness, directory,
effort, permissions, discard), the sidebar background (new session, form, add host, hide),
a host chip (filter, new session there, remove, add), and the composer (copy, clear, undo,
send, steer, model, effort, permissions). Menus take j/k, Enter and Esc too. Lifecycle chatter
(agent stopped, resumed, renamed, model set, stderr) is hidden; `/system` shows it. Real
failures, such as an unexpected exit or a failed resume, always show.

URLs and file paths in the transcript are OSC 8 hyperlinks, so Cmd-click opens them in
Ghostty, iTerm2, kitty, WezTerm and tmux ≥ 3.4 (paths become `file://` URLs resolved against
the session directory). Ctrl-click or Alt-click opens them from inside acpmux instead and
understands `path:line`: set `ACPMUX_EDITOR` (or `VISUAL`) to `code`, `zed`, `nvim`… to open
at the line. Markdown links show their URL after the text so it is visible and clickable.

Mouse selection also works in the composer: drag over the text and release to copy. In the
transcript, a drag that reaches the top or bottom edge keeps scrolling while the pointer stays
there. The composer grows to 12 rows before it scrolls; set `"composerMaxRows"` in
`~/.acpmux/config.json` or `ACPMUX_COMPOSER_ROWS` to change it.

## Peers: every session on every machine, from one Mac

A daemon can mirror other daemons. Add a peer and its sessions appear locally as
`<peer>/<name>`. `ls`, `attach`, `send`, `fork`, `set`, `allow`, and the TUI all work on them; every
request is forwarded over the peer's WebSocket and every event streams back.

The simplest peer is an SSH host. acpmux opens and supervises the tunnel itself and reads the
remote daemon's token over the same SSH access, so nothing is typed or copied:

```sh
# on the remote (any Mac or Linux box you can ssh to)
scp target/release/acpmux HOST:~/.local/bin/acpmux
ssh HOST '~/.local/bin/acpmux daemon'          # or install it under launchd / systemd

# on the Mac
acpmux host add HOST ssh://HOST                # ssh://user@host:port also works
acpmux ls                                      # HOST/session-name next to local sessions
acpmux attach HOST/session-name                # or plain `acpmux attach` for the full sidebar
```

Plain WebSocket peers work too, for hosts with a public address or an existing tunnel:

```sh
acpmux host add sandbox-a wss://sandbox-a.example.com:47811 --token "$TOKEN"
```

Everything works on a peered session: `send`, the TUI, permission prompts, fork, model and
mode changes. `Ctrl-t` from a peered session drafts a new session on that peer, and the
`Ctrl-l` picker lists remote harnesses as `HOST/agent`, so picking one starts the session
there. Peers reconnect with backoff, the tunnel included; while one is down its sessions show
`unreachable`. Peers are saved in `config.json` under `peers`.

A remote daemon needs a logged-in agent. Claude Code keeps its login in the macOS keychain, so
on a headless Mac run `claude` once in a terminal and log in before starting the daemon.

## Claude Code: native stdio backend

Claude Code sessions run over Claude's own headless protocol, not ACP:
`claude -p --input-format stream-json --output-format stream-json`. One `claude` process per
session stays alive until you stop it. acpmux translates the stream into the same events the
TUI, web page, and peers already understand, so nothing changes for the user.

What this gives over the ACP adapter: no injected MCP servers or hooks, real permission
prompts with Claude's own options, `AskUserQuestion` and plan approval answered from the TUI
or web page, model and mode changes mid-session, exact resume with `--resume`, fork with
`--fork-session`, and background Bash tasks that live as long as the session because the
process never exits between turns.

```json
"claude": { "kind": "claude-stdio", "argv": ["claude", "--model", "opus[1m]"] }
```

Everything after `claude` in `argv` is passed through, so `--settings`, `--mcp-config`,
`--allowedTools`, `--append-system-prompt`, and `--permission-mode` all work. `acpmux agents`
picks this backend automatically when `claude` is on PATH. Interrupt uses Claude's
`control_request` `interrupt`; the interrupted turn ends with `stopReason: cancelled` and the
process keeps running.

Stopping a session kills the agent's whole process group, so background shells the agent
started stop with it. Resume afterwards is exact, but the agent no longer remembers those
processes.

## Subrouter: Claude across many accounts

[Subrouter](https://github.com/manaflow-ai/subrouter) is a local proxy that spreads Claude and
Codex traffic across subscription accounts and fails over when one hits its limit. When `sr`
is installed, acpmux discovers a `claude-sr` profile that launches Claude through the pool
(`sr claude proxy`, which accepts acpmux's stream-json flags, `--session-id` and `--resume`),
and sets it as the `fallback` of the direct `claude` profile.

- `acpmux run -a claude-sr "…"` always uses the pool; the pool picks the account with the
  most quota and keeps the conversation sticky to it.
- A direct `claude` session whose account reports a usage or rate limit mid-turn is moved
  onto `claude-sr` automatically: the agent process is replaced by a pooled one that resumes
  the same Claude session, the prompt runs once more, and a `failover {from, to, reason}`
  event is logged. `session info` then shows `agent: claude-sr`.
- Any profile can name a `fallback` in `~/.acpmux/config.json`; the same rule applies to
  every harness, keyed on the error text (`reached your … limit`, `rate limit`, `quota`,
  `429`, `out of credits`).


Harnesses found on PATH join the configured ones at every start: `claude`, `codex-acp`,
`gemini`, `opencode`, and `pi-acp` (the ACP adapter for pi: `bun add -g pi-acp`). Entries in
`~/.acpmux/config.json` always win over discovery.

`~/.acpmux/config.json` (override the directory with `ACPMUX_HOME`):

```json
{
  "agents": {
    "codex":  { "argv": ["codex-acp"] },
    "claude": { "argv": ["claude-agent-acp"], "env": {"ANTHROPIC_API_KEY": "..."} }
  },
  "defaultAgent": "codex",
  "permissionPolicy": "ask",
  "store": { "mode": "local", "segmentBytes": 8388608 },
  "websocket": { "listen": "127.0.0.1:47811", "token": "change-me" },
  "peers": { "sandbox-a": { "url": "wss://sandbox-a.example.com:47811", "token": "..." } }
}
```

When no config exists, agents are imported from `~/.acpx/config.json` and from adapters on PATH.

- `permissionPolicy`: `ask` routes `session/request_permission` to attached clients and waits.
  `approve-all`, `approve-reads`, `approve-edits` (reads and edits auto, shell asks), and `deny-all` answer locally. Per-session override with
  `acpmux set NAME policy=...`.
- `store.mode`: `local` (default) or `memory`. Local writes `sessions/<id>/session.json` and
  append-only `events/NNNNNN.ndjson` segments.
- `websocket`: optional. The same protocol over WebSocket text frames, for remote clients such
  as a dashboard or a Durable Object. Put it behind a tunnel; the token is a bearer token.

## Protocol

Connect to `~/.acpmux/acpmux.sock` (newline-delimited JSON-RPC) or the WebSocket. acpmux is an
ACP agent: `initialize`, `session/new`, `session/load`, `session/list`, `session/prompt`,
`session/cancel`, `session/fork`, `session/set_mode`, `session/set_model`,
`session/set_config_option`, `session/close`, `session/delete`. Session ids are acpmux ids;
a name works anywhere a `sessionId` is expected.

`session/new` accepts `_meta.acpmux: {agent, name, policy}`. `session/prompt` accepts
`_meta.acpmux: {steer: true}`. Every `session/update` carries `_meta.acpmux: {seq, at}`.

Extensions:

| Method | Purpose |
| --- | --- |
| `_acpmux/status`, `_acpmux/agents`, `_acpmux/sessions` | Daemon and fleet state. |
| `_acpmux/attach {sessionId, afterSeq?, limit?}` | Subscribe and get the session detail plus recent raw events. |
| `_acpmux/detach`, `_acpmux/watch {enabled}` | Unsubscribe; or receive `_acpmux/session_changed` for every session. |
| `_acpmux/events {sessionId, afterSeq, limit}` | Page through the raw log. |
| `_acpmux/info`, `_acpmux/rename`, `_acpmux/kill {purge}`, `_acpmux/set_policy` | Session control. |
| `_acpmux/permission_respond {sessionId, permissionId, optionId}` | Answer a request announced by `_acpmux/permission_pending`. |
| `_acpmux/export {sessionId, dest}`, `_acpmux/import {path, name}` | Bundles. |
| `_acpmux/peers`, `_acpmux/peer_add {name, url, token}`, `_acpmux/peer_remove {name}` | Mirror remote daemons. |
| `_acpmux/shutdown` | Stop the daemon. |

Notifications to attached clients: `session/update` (standard), `_acpmux/event` (mux-internal
records such as `user_message`, `status`, `turn_end`, `permission_request`),
`_acpmux/permission_pending`, `_acpmux/session_changed` (watchers).

Any other method that names a `sessionId` is forwarded to the agent unchanged, so vendor
extensions keep working.

## Persistence and portability

Each session logs every JSON-RPC line in both directions plus acpmux records, with a
per-session sequence number. Clients resume from a sequence number after a disconnect.

`acpmux export` writes a bundle: `session.json`, `events/*.ndjson`, the adapter's own session
files under `native/` when the adapter is known (Codex rollouts, Claude Code project files),
and `manifest.json`. `acpmux import` on another machine restores the native files (never
overwriting existing ones) and resumes at the best level it can:

1. **exact**: `session/load` succeeded, tool state intact.
2. **rehydrate**: `session/load` was refused, so the next prompt starts a new agent session
   with the transcript embedded. The thread survives, tool state does not.

The level is recorded as a `resumed` event. Credentials never travel in a bundle.

## Tests

```sh
cargo test          # unit tests plus an end-to-end suite against tests/fake_agent.py
```
