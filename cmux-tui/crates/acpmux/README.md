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
of the session you were on; change them with `:agent NAME`, `:cwd PATH`, `:policy P` before
sending. The first Enter creates the session with that message. Esc on an empty draft discards
it. `:new form` opens the older field-by-field form instead. The bottom line of the TUI shows
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

## TUI

The TUI shares cmux-tui's chrome: the same 256-color palette for light and dark terminals, a
single-rule sidebar with two-line rows, a status bar with an active chip, bordered dialogs with
`[ Cancel esc ]  [ OK ⏎ ]` buttons, and the same scrollbar (`▕` thumb, `▐` while dragged,
invisible track, only drawn when rows overflow). Every dialog (help, pickers, permission
requests, forms, confirms) is one component (`src/tui/dialog.rs`): a fixed header, a body that
scrolls with the wheel, PgUp/PgDn, Home/End, track click or thumb drag, and a `N-M/T` counter
in the footer when rows overflow. Set `ACPMUX_THEME=light` or `dark` to override the
`COLORFGBG` guess.

Sidebar rows follow cmux rails: the current row is filled and carries a `▎` rail glyph, an
unread `•` marks sessions that finished a turn (green), wait for a permission (yellow) or
failed (red) while you were elsewhere, and the `+ new session` / `+ add host` actions stay
pinned at the bottom. The transcript pane has focus when its title is highlighted; there
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
Ctrl-l       pick model         Ctrl-o   pick mode        :set KEY  pick any option
:            command mode       ?        help
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

Command mode: `:new [agent] [name] [cwd]`, `:kill [--purge]`, `:fork [name]`, `:mode X`,
`:model X`, `:set key=value`, `:policy ask|approve-all|approve-reads|deny-all`, `:rename NAME`,
`:cancel`, `:export [dir]`, `:import DIR`, `:thoughts`, `:q`.

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

## Configuration

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
  `approve-all`, `approve-reads`, and `deny-all` answer locally. Per-session override with
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
