# acpmux

tmux for coding-agent harnesses. A Rust daemon keeps [Agent Client Protocol](https://agentclientprotocol.com)
agents (Codex, Claude Code, Gemini, OpenCode, Pi, ...) alive as named sessions, records every
wire message, and lets any number of clients attach, prompt, steer, cancel, fork, and change
model or mode. It speaks plain ACP to its clients plus a small `_acpmux/*` extension, so the
CLI, the TUI, a web dashboard, or a Cloudflare Durable Object all use the same protocol.

acpmux never makes outbound calls to a control plane. Something that wants to control it
connects to it.

## Build

Install the Rust toolchain and Zig version listed in the
[cmux-tui build prerequisites](../../README.md#build). From the repository root,
initialize the submodules before building:

```sh
git submodule update --init ghostty ghostty-next
cd cmux-tui
cargo build --release -p acpmux
mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/acpmux"
cp target/release/acpmux "$HOME/.local/bin/acpmux"
export PATH="$HOME/.local/bin:$PATH"
```

Remove the old binary first. On macOS, copying over an existing binary in place keeps the
inode, the kernel keeps the stale code-signature cache, and the new binary dies with signal 9.
The shell export lasts for this shell only; a service supervisor needs its own
PATH containing acpmux and the installed harness. `host doctor` checks
`~/.local/bin/acpmux` by default, so leaving the executable only in
`target/release` is not enough for that check. For SSH peering, harness login
and remote project access, follow [Remote agents and cmux Cloud](../../../docs/remote-agents-and-cloud.md).

## Quick start

```sh
acpmux                               # that is it: starts the daemon if needed, opens the TUI
```

`Ctrl-t` opens a new session tab at the top of the sidebar with an empty transcript and the
cursor in the editor, like opencode's `Ctrl-x n`. It inherits the agent, directory, and policy
of the session you were on; change them with `/harness NAME`, `/cwd PATH`, `/policy P` before
sending. The first Enter creates the session with that message. Esc on an empty draft discards
it. `/form` opens the older field-by-field form instead. The bottom line of the TUI shows
the web dashboard URL.

```sh
acpmux web                           # print the dashboard URL and open it in the browser
acpmux new -m codex -n backend-review   # scripted: create a session and open the TUI on it
acpmux new -m codex --tag task=review --tag owner=leo -n backend-review -d
acpmux send backend-review "inspect the failing tests"
acpmux ls
acpmux attach backend-review         # TUI on one session; Ctrl-q leaves, the agent keeps running
```

The daemon starts on demand, like the tmux server. `acpmux daemon` runs it in the foreground.

## Web dashboard

The daemon serves a dashboard on the same port as its WebSocket, by default
`http://127.0.0.1:47811/?token=…`. The token is generated on first run and saved in
`config.json`; `acpmux web` prints the full link and opens it. Only the local socket ever
reads it back: a remote-origin (WebSocket) connection gets no `webUrl` and no peer URL query.
Release note: earlier builds did send `webUrl` to WebSocket clients, so the first start of
this build replaces a saved token once (`websocket.tokenRotated` records it). Open the new
link from `acpmux web`, and give a `ws://` peer that pins the old token the new one; the app,
the TUI and `ssh://` peers read it again by themselves. The token stays the same across
launches on purpose: a `ws://` peer, a kept link and a browser on another machine have no way
to receive a new token at each start (the app's own LocalApp token and the peer token do change
at each launch). The daemon keeps `config.json` at mode 0600. `acpmux web --rotate-token`
replaces the token at once: the old link stops working and open dashboard and peer connections
that used it are closed. The page follows the Codex
desktop app like the TUI does: a rail with `New session` (a draft: `What should we build in
<project>?`, the harness and permission chips pick its settings, the project name opens the
directory picker, with separate harness, model, and permission buttons, and the session is created when you send the first message), sessions
grouped under their project with a `+` shortcut for starting there; the gear menu adds, hides, and reorders project shortcuts. They are titled by their first prompt (hover one for its card, `⋯` or
a right-click for rename, fork, stop, delete), the hosts at the bottom; a centered conversation with
timestamps, your messages as right-aligned bubbles, each turn's work folded under `Worked for
19s ›` with an `Edited N files +a -d` card listing each file, muted activity rows with diff
counts and colored diffs on edits, `Thought · summary` rows, real markdown with code blocks
and a Copy button, failed turns as notice cards, queued messages waiting at the bottom; a
rounded composer with the permission, mode, model and effort chips inside; and a pending
permission docked above it (`y`/`n` answer it from the keyboard). Every session, local and
peered, streams live. Dark by default, light through the OS or `?theme=light`; `?open=1`
unfolds every turn, `?session=<name>` opens one, `?session=new` (or `&draft=1`) starts a
draft. Keys: `⌘K`/`Ctrl-K` new session, `Alt-↑`/`Alt-↓` (or `Alt-j`/`Alt-k`) walk the rail,
`y`/`n` answer a permission, `Esc` in the composer cancels the turn. On a phone the rail is a
sheet behind a `Sessions` button. To reach it
from another machine, set `websocket.listen` to a non-loopback address and put a tunnel or
firewall in front. Clients may then connect by IP address; list every host name they use (a
tailnet name, for example) in `websocket.allowedHosts`, because any other `Host` is refused.

### Remote connections (`webRoots`, `webAskingModes`)

Every connection is authenticated before it gets a session or any data. Each one carries the
proof it presented (`ConnAuth`, `src/server/conn_auth.rs`), reported as `initialize`
`_meta.acpmux.auth`: `localSocket` (the daemon socket, owner-only), `listenerToken` (the
WebSocket token, checked at the upgrade; a missing or wrong token gets 401 and no connection),
`localApp` (the token plus this launch's LocalApp token) or `peerToken` (the token plus this
launch's peer token). A connection with no proof (`none`) gets error -32001 for its first
request and is closed. The mode rule reads `ConnAuth::authenticated`, not the transport.

A WebSocket connection other than the app's own pane (the dashboard, a paired or relayed
device, a peer daemon) works only inside folders that are known projects (the cwds of local
sessions) or listed in `webRoots`, and only in modes that ask before they act: the reviewed
per-harness table in `src/server/remote_guard.rs` plus what `webAskingModes` adds, for example
`"webAskingModes": {"myharness": ["ask"]}`. Both live in `config.json` and are never written over
a WebSocket. **Warning: a mode that you add to `webAskingModes` lets paired devices start that
mode without a per-action prompt.** See `plans/cmux-next/acp-remote-guard.md`.

A connection proven a peer (the peer token above) reads this daemon's session summaries with
their text masked (`src/server/peer_text.rs`): a token pasted into a prompt shows as
`[GitHub Personal Access Token]` in the title, the prompts (running and queued), the preview, the
last message and the last turn's error, in an ACP `session/list` entry's title, and in a chat's
title and preview; a field past 16384 characters is cut. Every peer is masked: the peer token is
shared by all of them, so none can be told apart to trust. A peer may not rewrite a queued prompt
that holds a secret (it may still move, send or remove it). The unix socket, the app and the dashboard keep the raw text, and so does a peer
daemon served as Web (its peer token withheld over plain `ws://`). Only those summary fields are
masked: a session's updates, events, history, chat transcripts and tool output still reach a peer
raw.

## CLI

### Remote ergonomics

Use a non-interactive SSH probe before saving a peer. If the first attempt is
offline, `acpmux host add` saves the peer, exits 0, and prints a warning to
stderr. With `--json`, the response instead includes a `warning` object with
`reason: "peer_unreachable"`, the exact `ssh -o BatchMode=yes HOST true` probe
in `try`, and `detail: "the peer was saved and will keep reconnecting"`.
For WebSocket URLs, `try` is `acpmux host ls`. Saving failures remain errors.
Peer requests that cannot be sent include `acpmux host ls` and state that the
request was not sent. A method rejected by an older peer is reported as
`peer_version_skew` with `acpmux host update NAME`.

`ACPMUX_SOCKET` takes precedence over `ACPMUX_HOME`. To inspect an isolated
home from a shell that may be inside another agent, use
`env -u ACPMUX_SOCKET ACPMUX_HOME=/tmp/example acpmux daemon status`; inspect
the selected socket before stopping a daemon. `host enroll` preserves a saved
peer's explicit listener port instead of assuming 47811.

`host doctor --harness ID` distinguishes a local profile that can be copied
from a harness discovered by the remote daemon. For the latter, run
`acpmux daemon harnesses`, then verify with a real `acpmux new --host` session
and prompt. `harness doctor` classifies a Codex app-server's
`unknown variant session/new` as a protocol mismatch and points to the acpmux
bridge; it does not suggest a login command for that error. Remote permission
requests must be approved in the cmux Mac app's pending-permission card; the
CLI allow command is refused on this route.

Five everyday commands, three groups for the rest:

| Command | What it does |
| --- | --- |
| `acpmux` | Open the TUI. Starts the daemon if needed. |
| `new [-m harness[/model]] [-n name] [--cwd dir] [--policy p] [prompt]` | Create a session. Opens the TUI unless `-d`. |
| `send NAME "text" [--steer\|--no-steer] [--no-wait] [-q]` | Prompt and stream the reply. With `--no-wait` it hands the message to this daemon and returns at once with a delivery id, for a session here or on a peer ([the outbox](#messages-to-other-sessions-the-outbox)); it steers into a running turn by default (read at the agent's next tool boundary, never stopping it) and queues when the agent does not steer. An agent's send steers by default even when it waits for the reply, and then prints the reply of the turn it went into; the person's waiting send queues unless given `--steer`, and `--no-steer` queues any send. `--supersede KEY` replaces the sender's own prompt still queued under KEY (never one whose turn started); with `--no-wait` it prints `replaced N queued` once delivered (`?` from a daemon that predates it) and `--json` adds `replaced` and `replacedPromptIds`. The sender is the agent (`--from`, or the session `send` runs in) or, for anything else, the person. `--attach FILE` (repeatable) sends files with it, to a peer's session too: an image (its type read from its bytes) reaches the agent and the transcript as an image, any other file as a link to its copy, saved owner-only under the session's `uploads` on the host that runs it; at most 8 MiB a file and 10 MiB and 16 files a message (the message is one frame on every hop). |
| `send --status ID` | A `--no-wait` delivery's state: `queued`, `delivering` (attempt n), `delivered` (the target's turn, steered or queued), `held` (a paused agent pair holds it until the person resumes the pair) or `failed` (the last error). |
| `ls` | Sessions on every host, as `host/name` for remote ones. |
| `attach [NAME] [--plain]` | TUI on one session, or a plain text stream. |
| `web [--no-open] [--rotate-token]` | Print the dashboard URL and open it; `--rotate-token` replaces the token first. |
| `host setup HOST [--no-auto-update]` / `host update [--all] [--if-idle] [--keep-newer] [--binary-dir DIR]` / `host self-update` / `host add NAME [URL]` / `host ls` / `host status [NAME]` / `host rm NAME` | Remote daemons. `setup` installs over ssh; URL is `ssh://host`, `ws://…`, or `wss://…` (default `ssh://NAME`: the machine's one daemon as your ssh config reaches it). `ls` names an `ssh://` entry with a user or another port as not the canonical endpoint. `status` (also the hidden `peer status` alias) asks each host's health live: reachable, round trip, disk, load, live sessions, build. |
| `host enroll HOST [--harness ID]… [--reverse]` / `host doctor NAME\|HOST [--fix] [--reverse]` | Add a machine step by step (reach, install, daemon, harness, peer, peer-back, identity), one JSON line per step with `--json`; `peer-back` (this machine as the host's peer) runs only with `--reverse`; `doctor` changes nothing without `--fix`. |
| `session info\|cancel\|stop\|rename\|fork\|set\|allow\|deny\|export\|import\|tail NAME …` | Everything about one session. |
| `daemon run\|status\|shutdown\|config\|harnesses\|reload\|models\|schema` | The daemon itself. |
| `capabilities [--json]` | The protocol capability ids this build serves (`acpmux-v1`, `queue-edit-v1`, ...), with no daemon running. |
| `daemon shutdown [--end-agents]` | Stop the daemon; the user sessions' hosted agents keep running for the next daemon (a restart or an update), as with SIGTERM. `--end-agents` also ends every agent host it owns, exits 0 only when none is left, and names any host that survives SIGKILL. `--keep-agents` is accepted and changes nothing (a plain stop of builds before 2026-10-15 ended the agents). |

The older flat spellings (`acpmux kill NAME`, `acpmux peer add …`, `acpmux status`) still
work but are hidden from help.

`--json` on any command prints the raw response.

## Orchestrating agents from scripts

Every command takes `--json` before it for machine output; errors then go to stderr as one
`{"error": {"code", "detail", "message", "sessionId", "retryable"}}` object and nothing is
printed on stdout. Exit codes are stable: 0 ok, 1 runtime or agent error, 2 usage, 3 timeout,
4 no such session, 5 every permission in the turn was denied, 130 interrupted. A closed daemon socket is never reported as a bare "connection closed": the
message says what was in flight, whether the daemon is still running, exited without cleanup, or
was shut down, which build it ran when that differs from the CLI's, and where the log is
(`detail: daemon_closed`, retryable). When a prompt was in flight the error also carries its
`promptId`: `acpmux send NAME --prompt-id ID "…"` (or `run --prompt-id`) sends it again safely,
because the daemon runs a prompt id once and answers a repeat with the first run's outcome, even
after a restart. `--no-wait` and `--detach` return once the daemon has accepted the prompt. The TUI
reconnects on its own when the daemon restarts and re-attaches the selected session.

A failure acpmux knows the remedy for says what to do on the next line, and under `--json` adds
`errorKind` and `recovery` to the error object (the [typed errors](#typed-errors) below):

```
acpmux: runtime: No space left on device (os error 28)
  The disk is full. Free space on the disk that holds /home/me/proj: 0.4 GB free of 252 GB.
```

```
acpmux run -m codex --cwd ~/proj "fix the failing test"      # new session, send, print only the reply
acpmux exec -m claude "one-shot"                              # same, and the session is deleted afterwards
acpmux --json run -m claude --policy approve-all "..."       # {"sessionId","name","reply","stopReason","permissions",…}
acpmux ensure NAME -m codex --cwd DIR                         # the session if it exists, else create it
acpmux ensure NAME -m codex --tag task=review                  # repeatable creation-time labels
acpmux send NAME --no-wait "..."                              # hand it over and return at once; prints the delivery id
acpmux send --status ID                                       # queued, delivering, delivered, held or failed
acpmux send NAME --timeout 120 --on-permission deny|fail "…"  # cancel after 120 s (exit 3); answer prompts without a human
acpmux wait                                                   # until any session on any host resolves (turn ended or needs a permission)
acpmux wait NAME… --until ready|permission|closed|done|running [--all] [--timeout 300] [--print] [--notify]
acpmux wait NAME --match "tests pass" | --regex "pass(ed)?"   # until the agent's output contains it
acpmux last NAME [-n 3]                                       # last reply text
acpmux history NAME                                           # one line per turn: status, wall time, tools, tokens, prompt
acpmux pending                                                # every pending permission, and how to answer it
acpmux session deny NAME                                      # an allow is the cmux app's alone (the chat's permission card)
acpmux session rules NAME '{"autoDeny": ["rm -rf"], "ask": ["execute"], "default": "approve"}'
acpmux session limits NAME [--max N | --clear]                 # sub-sessions running at once (more wait), running and queued now
acpmux session tag NAME task=review --ttl 3600; acpmux ls --tag task=review
acpmux ls --status running | --pending                        # filters; --json for the full records
acpmux session tail NAME --since <sessionId>:<seq> --follow   # raw events as JSON lines; a cursor past the log is exit 2
acpmux compare -m claude -m codex/gpt-5.5 "prompt"                    # one temporary session per harness, run one after another
acpmux guide                                                  # the agent guide (also --guide, --skill); acpmux daemon schema prints the RPC surface
```

Waits run in the daemon: a per-session `stateSeq` bumps on every status, permission and
turn change and the wait subscribes to hub events, so nothing is missed between the check
and the subscribe. `done` means a turn ended while no client was attached. `send` reports
`prompt_stalled` (exit 1) when the agent produces nothing for 30 s (`--stall 0` disables); the
turn keeps running. `run --retries N` retries only agent-internal errors that produced nothing.

The daemon supports durable wake subscriptions through the local socket methods
`_acpmux/watch_add`, `_acpmux/watch_ls`, and `_acpmux/watch_rm` (`durable-watches-v1`).
Add takes `to`, explicit nonempty `sessions` (including `HOST/name`), `until`, optional
`match`, and `once` (only true is supported). It delivers batched ordinary messages with reply excerpts
and inspection commands. Watches and undelivered messages survive restart; an offline peer
produces one notice without resolving. Failed deliveries remain visible in the list and retry
on a relevant session/peer change or restart. A one-shot watch is removed after delivery.
Unreadable watch state is preserved as `watches.json.bad-<timestamp>`; the daemon starts
with no watches. Older cursor fields default safely. Peer replay uses eight workers.
The CLI and MCP watch tools are not exposed yet; `acpmux wait` remains the script interface.

Agents spawned by acpmux get `ACPMUX_ENV=1`, `ACPMUX_SESSION_ID`, `ACPMUX_SESSION_NAME` and
`ACPMUX_SOCKET`, and `@` names that session (`acpmux last @`), so an agent can drive its own
session and siblings. The event log carries `turn_started` and `turn_result`
(`completed|cancelled|failed`); a daemon that restarts mid-turn writes
`turn_result failed outcome_unknown` so nobody replays a prompt that may have run. A turn a
connection error cut off ("stream disconnected", a refused or reset connection, a 502/504), or
that the provider or the gateway had no capacity for (HTTP 503 or 529, `overloaded_error`, "no
non-exhausted ... accounts", "at capacity"), goes on by itself in the same session: after `autoResumeDelaysMs` (default 10 s, 1 min, 5 min, 20 min; `[]` turns it
off) the chat gets one prompt telling the agent to check what finished and continue, with prompt
id `<promptId>~resume-<n>` and `_meta.provenance.kind` `auto_resume`. Stop, closing the chat, or
anything else run in it meanwhile cancels it, and a continuation that completes resumes the
prompts the cut turn held (`hub/auto_resume.rs`). While it waits the session row's `retry` is
`{attempt, of, reason, nextAt, promptId, turnId}` (`reason` `capacity`, `transport` or
`agent_exited`), null otherwise. Usage limits and sign-in failures never retry this way.
`acpmux retry NAME` (`_acpmux/retry {sessionId}`, the Retry button; the sub-session tool
`retry_session`) retries a failed last turn now, under the caller's rules, taking over a waiting
retry: the failed prompt goes again as its next `~resume-<n>` (a continuation when the turn had
output, joined agent messages or hidden context); `retry.busy` while a turn or a retry runs,
`retry.stopped` when Stop comes before it starts, `retry.nothing_failed` when nothing failed.
With `subagentId` (`acpmux retry NAME --subagent ID`, `retry_session {subagent}`; capability
`subagent-retry-v1`) it resumes that failed subagent instead, by its id or agent id: a waiting
automatic retry fires now, else one more goes, as the prompt the automatic one sends
(provenance `subagent_retry` with `manual: true`, prompt id `subagent-retry-...`); it answers
once that turn started and never queues. It refuses `retry.busy` while a turn runs or is about to
start (Claude Code's own too), a prompt waits, a continuation may fire, the chat moves, a
sub-session's run slots are full, or that subagent's retry is under way;
`retry.nothing_failed` (`data.why`: `closed`, `running`, `resumed`, `replaced`, `ended`,
`forgotten`, `not_retryable`, `skipped`) and `retry.unknown_subagent`, never the chat's own
turn. A
`notifyCommand` in the config runs on a permission request and on a turn that ends
unattended, with `ACPMUX_EVENT`, `ACPMUX_SESSION_NAME` and `ACPMUX_TEXT` set.
`agentStartTimeoutMs` (default 90000) bounds a cold agent start (spawn, `initialize`,
session load or new, config replay): past it the request fails with code -32000 and
`data.reason` `deadline_exceeded` (`data.wait` `agent_start`), the agent is ended, the
session stays open, and the log gets `agent_start_timed_out`.
`silentTurnMs` (default 90000; 0 turns it off): a turn whose model shows no sign of work
(no message, thought, tool call, plan, compaction or request, and no harness line only a
responding model produces, such as Claude's stream and thinking or Codex's moderation
notice; the agent's own usage and turn notices do not count) for that long after its
prompt (a stalled model) logs `turn_silent` {turnId, silentMs} once, so a client can say
the model has not answered. The model's first sign after it logs `turn_heard` {turnId}.
`stalledTurnMs` (default 600000; 0 turns it off): a running turn with no tool call in
flight whose model has shown no sign for that long has stalled: `lane.stalledSince` (and
`turn.stalledSince`) say since when, and the lane's state stays `working`. A long build in
one tool call is in flight, so it never stalls. It is checked when a summary is read, with
no timer.
`stalledTurnEndMs` (default 21600000, 6 h; 0 turns it off): a running turn whose model has
shown no sign of work, counted the same way, for that long (four times that while one of its tool
calls has not ended; also across a daemon restart: an adopted
turn's count and start come from its log) ends as failed, `turn_result` `detail` `stalled`
with `stalledMs` and `errorSource` `acpmux`. The agent gets the cancel and the turn ends even
if it never answers. Only a turn nobody holds: no client that shows the chat, no permission or
secret waiting, and its recorded owner (a sub-session's parent, the session a `spawnedBy` tag
names) not running or waiting. The chat stays open and its idle agent exits as any unused one
does; the next prompt resumes it.
Files dropped into a chat (`_acpmux/file_put`, under `<home>/uploads/<session>/`) are
deleted with the chat (`_acpmux/kill` with purge) and once older than `uploadsMaxAgeDays`
(default 30; 0 keeps them), checked at the daemon's start and daily.

A chat whose harness never titles it (Claude Code's `-p` stream-json has no title
event) gets an instant first-message placeholder, then a 3-6 word model title, logged
as `titled`. A thin first message may get one refresh after its first completed turn;
later turns never retitle it. `titles.command` (an argv reading the request on stdin
and printing the title; env `ACPMUX_TITLE_COMMAND` wins) makes it; unset, `_acpmux/complete`
uses the harness's cheap model (Haiku for Claude, a small Codex model where available)
with no tools, MCP or session file. A harness or manual title always wins, a chat titled
before this (or adopted) keeps its title, and `titles.generate: false` turns it off.
The daemon logs the title model, elapsed time, and estimated input/output token cost for
each generated title.

## TUI

The TUI is modelled on the Codex desktop app, screenshot by screenshot: a shaded sidebar
without a rule, a conversation with muted activity lines, and a rounded composer with its
controls inside. The same 256-color palette serves light and dark terminals (set
`ACPMUX_THEME=light` or `dark` to override the `COLORFGBG` guess). Every dialog (help,
pickers, forms, confirms) is one rounded-corner component (`src/tui/dialog.rs`): a fixed
header, a body that scrolls with the wheel, PgUp/PgDn, Home/End, track click or thumb drag,
and a `N-M/T` counter in the footer when rows overflow.

**Sidebar.** `✎ New session` on top; each local project header has a `+` shortcut for a new
session in that directory. Sessions are grouped under their project (`▢ acpmux`, or
`▢ host · project` for a peer, `~` for a home directory), one line each, titled by their first
prompt when the name was generated and by the name you gave otherwise; a mark at the right
edge (`?` needs a permission, `●` running, `•` finished or failed while you were elsewhere,
`!` disconnected); `+ Add host` pinned to the bottom. The selected and hovered rows are full-
width shades. Drag the sidebar's right edge to resize it.

**Header.** `▢ project  ›  session`, a status word only when it needs attention (`needs
permission`, `disconnected`), token use at the right edge.

**Transcript.** The conversation, the composer and a permission card share one column of at
most 124 cells, centered when the terminal is wider. A centered muted timestamp (`Today 2:15
AM`) before each of your messages,
which sit right-aligned in a tinted bubble (at most seven tenths of the width) with `❯`. The
turn's work follows under a handle with a hairline, `Worked for 19s  ▾` (or `Working for 4s`
while it runs), from the daemon's turn markers: each
thought as `Thought  <first line>  ›`, each tool call as one muted line with a kind glyph
(`≡ Read calc.py`, `$ echo hi`, `✎ Edited calc.py  +2 -1`, `⌕ Search …`), paths cut to the
file name, red only when it failed; a run of tool calls collapses into `3 steps · Read, Bash,
Edit`; permission rows read `? Needs permission`, `✓ Allowed`, `✗ Rejected`; a failed turn is a
rounded notice card. Edits carry a
diff: the counts on the row, and the `+`/`-` lines in the diff colors when opened. The final
reply is plain markdown with no bullet. Click any handle, thought or tool line to open or
close it; it lights up under the pointer. The thought being streamed stays open; `/thoughts`
opens them all.

**Composer.** A rounded box: your text (growing to twelve rows), and along its bottom edge the
permission chip (`Full access` in a warm accent, `Edits allowed`, `Reads allowed`, `Ask
before acting`, `Read-only`), the harness mode when it is not the default, and at the right
the model, the effort and a `↑` send glyph. Every chip is clickable and opens its picker.

**Permissions.** A pending request is a card docked above the composer, `Needs permission ·
Write perm.txt`, with the options as chips; `y`, `n`, a digit or a click answers it. Nothing
covers the conversation.

**Empty states.** A new draft or a session without messages shows `What should we build in
<project>?` centered, with separate clickable harness, model, effort and permission settings under it.
Click the project name in the headline or header to choose a directory.

The status bar shows hosts (click one to filter the sidebar), the last message, `? keys · /
commands`, and a `web dashboard ↗` link. Errors are red rows in the transcript and a red
status-bar message with a `[copy]` button.

Model pickers list every model a harness declares or reports. At start the daemon probes each
ACP harness once (spawn, `initialize`, `session/new`, read the list, kill) so Codex, OpenCode,
pi and their forks show their catalogs before any session exists; Claude uses a fixed alias
table.

```
Enter        send prompt        Ctrl-s   steer, or queue when the agent cannot steer
Ctrl-t / n   new session tab    Alt-n     new session tab    Ctrl-g   cancel turn
Cmd-Ctrl-h/j/k/l  move focus like cmux panes: h sidebar, l content, k transcript, j composer
                  (Alt-h/j/k/l on terminals that do not deliver Cmd)
Tab          focus sidebar (Option-j/k or arrows, x stop, f fork, r rename); Esc or Enter back
Ctrl-n/p     next / prev line in the composer (history at the ends); next / prev session in the sidebar
Alt-s        hide / show the sidebar (`:sidebar`); Alt-h shows it again
Alt-←/→      narrow / widen the sidebar (or drag its rule; the transcript keeps 40 columns)
Alt-1…9      jump to a visible session       Alt-[ / Alt-]   previous / next session
Ctrl-l / Alt-m  pick model       Alt-p     permissions     Alt-Shift-d directory
Ctrl-o       pick mode           Alt-e     pick thinking effort
/            command palette    ?        help             Esc       interrupt the running turn
/set KEY     pick any option    /set KEY=VALUE            Ctrl-Shift-p / Cmd-k also open the palette
wheel PgUp/PgDn scroll          Home/End top / follow the bottom
y / n / 1-9  answer permission  Ctrl-q   quit (agents keep running)
```

The compatibility choices below follow OpenCode's [TUI commands](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/tui.mdx),
[keybind conventions](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/keybinds.mdx),
and [skill discovery](https://opencode.ai/docs/skills).

`Ctrl-x` is now a sequential leader: release it, then press `p` for commands, `n`
for a new session, `m` for models, `l` for sessions, `a` for agent modes, `b` for
the sidebar, `d` for directories, `k` for skills, `h` for help, or `q` to detach.
Esc cancels a pending chord; unfinished chords expire after two seconds. Cancelling
a running turn remains on Esc (in the composer) or Ctrl-g. Option-d keeps its
Readline delete-next-word behavior; Option-Shift-d opens directories.

### Skills and UI configuration

Type `$` at the beginning of a word in the composer to pick a skill, or use
`/skills`. Enter inserts `$skill-id`; Esc preserves a literal `$` and the typed
filter (for example `$HOME`). You can also paste or type a known `$skill-id`.
On send, acpmux attaches that skill's instructions and base directory to the
prompt, so relative reference files can be found by the harness. Unknown names,
shell variables, escaped references and references inside code stay literal.
Skills are loaded for the selected local project at send time. Remote sessions
keep their harness's native skill handling; local skill files are not silently
substituted into remote prompts.

Discovery reads `SKILL.md` below global `~/.claude/skills`, `~/.agents/skills`,
`~/.codex/skills`, `~/.config/opencode/skills`, and `~/.acpmux/skills`, plus matching
project directories from the repository root down to the selected directory.
Root-level named Markdown skills are accepted too. Project definitions override
global ones; `skillPaths` adds higher-priority directories. No skill scripts run
during discovery or selection.

Configure the TUI in `~/.acpmux/config.json` (or `$ACPMUX_HOME/config.json`):

```json
{
  "tui": {
    "palettePrefix": ":",
    "paletteAliases": ["/"],
    "skillPrefix": "$",
    "leader": "ctrl+x",
    "leaderTimeoutMs": 2000,
    "skillPaths": ["./skills", "~/shared-skills"],
    "keybinds": {
      "command_list": "ctrl+p,<leader>p",
      "session_new": ["alt+n", "<leader>n"],
      "model_list": "<leader>m",
      "cwd": "ctrl+x g d",
      "quit": "ctrl+q",
      "toggle-sidebar": false
    }
  }
}
```

Prefixes are one character; the default palette prefix is `/` and the default
skill prefix is `$`. A different palette prefix frees `/` for ordinary input
unless it is listed in `paletteAliases`. Changes take effect when opening a new
TUI; no daemon restart is required. Invalid settings fail with an explanation.

Keybind keys are acpmux action names from the command palette; supported OpenCode
aliases include `command_list`, `session_new`, `session_list`, `model_list`,
`agent_list`, `sidebar_toggle`, `app_exit`, `help_show`, `session_interrupt`,
`prompt_skills`, `variant_list`, `workspace_set`, `messages_page_up`,
`messages_page_down`, `messages_first`, `messages_last`, and `display_thinking`.
`session-1` through `session-9` control direct session jumps. Values replace the
action's global shortcuts; use a comma-separated string or an array for alternatives,
spaces for sequences, `<leader>` for the configured leader, and `false` or `"none"`
to disable a global action binding. Readline editing and modal navigation remain
contextual; configured global bindings run first outside dialogs. Help and the
palette show the effective bindings. For OpenCode's Ctrl-p command palette, use
`command_list: "ctrl+p,<leader>p"`; the default keeps Ctrl-p for previous-line editing.

OpenCode command aliases `/models`, `/sessions`, `/resume`, `/continue`, `/clear`,
`/exit`, and `/thinking` are supported. Harness commands such as `/compact` are
forwarded only when the selected harness advertises them. OpenCode's Git-backed
message undo/redo, shell execution, sharing, and provider setup are not emulated;
acpmux's `/undo` edits the composer only.

Type `cd` and press Enter to open the directory browser. `cd ..`, `cd ../other`,
`cd ~/project`, `cd "My Project"`, and `cd -` preselect a path there. Relative paths
start at the selected session's directory. Click parent/child folders, then
**Use directory**. Cancelling preserves the typed command. A draft moves to the
chosen directory; an existing agent keeps its directory and a new draft opens.

The message editor is a real editor: cursor anywhere, Left/Right, Home/End, Ctrl-a/Ctrl-e,
Alt-b/Alt-f or Alt-Left/Alt-Right by word, Ctrl-w and Alt-Backspace delete a word back, Alt-d
forward, Ctrl-k to end of line, Ctrl-u to start of line, Ctrl-d or Delete forward, Ctrl-z undo.
Newline with Ctrl-j, Shift-Enter, or a trailing `\` then Enter. Up and Down move across lines;
at the top or bottom they recall sent messages. Paste inserts at the cursor. The box grows to
eight rows and scrolls inside after that; click to place the cursor.

The composer's chips change the session: the model list covers every harness on every host
and forks into a new session tab when you pick a different harness; mode, permissions and
effort apply to the running session at once; effort shows only for harnesses that expose
one. `/cwd` opens a directory dialog: on a draft it just changes, on a running session it
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
`/harness NAME`, `/set KEY[=VALUE]`, `/thoughts`, `/host add NAME URL`, `/export`, `/import`,
`/web`, `/quit`.

Thinking effort: Claude Code (`--effort` at spawn, live `apply_flag_settings`), the Zed
Claude adapter (`effort`) and Codex (`reasoning_effort`, up to `ultra`) all expose it. acpmux
calls it `effort` everywhere and maps the name onto the harness's own option, so
`acpmux new --effort high`, `acpmux session set NAME effort=low`, `/effort max`, Alt-e and
the `thinking` chip all work on any of them. OpenCode and Gemini do not expose one over ACP.
Assistant text renders as markdown (pulldown-cmark): headings, emphasis, inline code as
shaded chips, links in the link color, nested lists, quotes, rules, simple tables, and fenced
code blocks on a shaded background with a language header and syntect highlighting when the
language is known. Markdown spacing follows Codex's renderer: a blank row between blocks, list
items kept together with `- ` and `N. ` markers indented four columns per level, headings bold
(h1 underlined, h3 italic). Your message shows the instant you press Enter; the daemon's echo
is matched, not repeated. Right-click a row for Expand/Collapse everything, Copy message, Copy
row, and Open link.

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
there, and a selection covers only the useful text: the gutter, role markers and trailing
padding are never highlighted or copied. The composer grows to 12 rows before it scrolls; set `"composerMaxRows"` in
`~/.acpmux/config.json` or `ACPMUX_COMPOSER_ROWS` to change it.

## Bring your own harness

Any harness can be added with one profile file (`~/.config/cmux/harnesses/<id>.toml`), checked
with `acpmux harness doctor <id>` (also available under the `cmux harness` scope). Schema, secrets, terminal harnesses,
folder profiles and the ACP adapter guide: [docs/add-your-harness.md](../../../docs/add-your-harness.md).

Your own model endpoint is a harness too (a Chief can use it as its backend):

```sh
cmux harness add acme --example anthropic-endpoint --base-url https://llm.example.com --model acme-large
cmux harness add local --example openai-endpoint --base-url http://127.0.0.1:11434/v1 --model qwen3
cmux harness secret set acme ANTHROPIC_AUTH_TOKEN   # or CMUX_BYO_API_KEY; hidden prompt
cmux harness doctor acme                            # one real hello turn; names the fix
```

`anthropic-endpoint` runs acpmux's own Claude Code adapter with `ANTHROPIC_BASE_URL`,
`ANTHROPIC_MODEL` (also the small/fast model) and `ANTHROPIC_AUTH_TOKEN` from the Keychain; no other
inherited `ANTHROPIC_*` or Claude provider switch reaches it. `openai-endpoint` runs `opencode acp`
with an inline `OPENCODE_CONFIG_CONTENT` (provider `byo`, `@ai-sdk/openai-compatible`, model
`byo/<model>`) and its key in `CMUX_BYO_API_KEY` from the Keychain. The daemon methods are
`_acpmux/harness/add {example, id, displayName, baseUrl, model, keychainItem}`,
`_acpmux/harness/secret/set {id, key, value}` (the value is never echoed) and
`_acpmux/harness/doctor {id, prompt: true}`; all three take the unix socket only.

## Picking a harness and a model: `-m HARNESS[/MODEL]`, `-p PRESET`

One flag names what runs. Its head is a **family** (`claude`, `codex`, `opencode`, `pi`, `omp`,
`prime`, `gemini`) or a **profile** (`claude-sr`, `claude-acp`); an optional model follows the
first slash and keeps its own slashes. Nothing is inferred: a head that is neither family nor
profile is an error, and when it looks like a model id the error says what to write instead.

```sh
acpmux run -m claude "…"                          # the claude family: its preferred profile and defaults
acpmux run -m claude/opus "…"                     # that harness, that model
acpmux run -m codex/gpt-5.5 "…"
acpmux run -m opencode/zai/glm-5.1 "…"            # provider/model ids keep their slashes
acpmux run -m opencode/big-pickle "…"             # OpenCode lists it as opencode/big-pickle: the full id is used
acpmux run -m pi/subrouter/gpt-5.6-sol "…"
acpmux run -m omp "…"; acpmux run -m prime "…"    # forks are their own families
acpmux run -m gpt-5.5 "…"                         # error: "gpt-5.5" is a model id: write codex/gpt-5.5
acpmux run "…"                                    # no flag: the default harness and its defaults
```

| Model id style | Harnesses | Examples |
| --- | --- | --- |
| bare id or alias | Claude Code, Codex, Gemini | `claude/opus`, `claude/claude-fable-5-1[1m]`, `codex/gpt-6-astra`, `gemini/gemini-2.5-pro` |
| `provider/model` | OpenCode, pi, oh-my-pi | `opencode/opencode-go/deepseek-v4.1-flash`, `pi/anthropic/claude-opus-5`, `omp/openai-codex/gpt-5.6-sol` |
| none over ACP | prime-agent | `-m prime`; the model comes from its own settings, or from a `${model}` argv entry (below) |

`acpmux daemon models` prints every id each harness declares or reports; `--refresh` probes
again after you change a harness's provider config.

If acpmux was already open when you edited `~/.acpmux/config.json`, reload the catalog without
stopping any existing agent:

```sh
acpmux daemon reload
# or /reload in the TUI
```

This rereads harnesses, defaults, and presets, starts background model probes, and leaves every
current session and child process attached to its existing harness. A profile removed from the
file remains available for existing sessions. The daemon must be running a
build that includes this command; installing a newer binary does not restart the current daemon.

**A family resolves to exactly one profile, or fails.** Its `prefer` list, else its only
profile, else the profile named like it. Two profiles and no preference is an error naming
both, never a guess. By default `-m claude` is the user's own Claude login. When a CodeRouter
route is configured (`coderouterClaudeRoute`, below), discovery sets `claude` to prefer
`claude-cr` then `claude`. The subrouter pool (`claude-sr`) is never preferred automatically;
choose it with `acpmux defaults claude prefer=claude-sr,claude` or `-m claude-sr`.

**Defaults** fill in what the flag leaves out, per family or profile: model, effort, policy,
env. Precedence: explicit flags, then the preset, then the profile's entry, then the family's.

```sh
acpmux defaults                                            # one row per family: profile chosen, model, effort, policy
acpmux defaults claude model=opus effort=high policy=approve-edits
acpmux defaults codex  effort=high
acpmux defaults claude env.ANTHROPIC_BASE_URL=http://127.0.0.1:4000
```

**Presets** are named bundles for `-p`: one harness plus model, effort, policy and env. A preset
names one harness, so it does the same thing every time; want a different harness on another
machine, define the preset differently there.

```sh
acpmux preset deepseek harness=deepseek model=deepseek-v4.1-flash effort=high
acpmux preset opencode-v2-deepseek harness=opencode-v2 model=opencode-go/deepseek-v4.1-flash
acpmux preset omx harness=codex 'env.CODEX_HOME=${cwd}/.codex'      # oh-my-codex project homes
acpmux run -p deepseek "…"
acpmux run -p omx --cwd ~/proj -m codex/gpt-5.5 "…"                 # -m and -e still win over the preset
acpmux preset                                                        # list; `preset NAME --clear` removes one
```

A preset's `args` are words appended to the harness command line, given as one JSON list
(`acpmux preset compact harness=claude-sr 'args=["--tools", "", "--no-session-persistence"]'`).
Each entry is one argv word passed as it is, never through a shell. They are an allowlist that
can only take capabilities away: on a Claude Code harness `--tools ""` (an empty value only),
`--strict-mcp-config` (no `--mcp-config` may be given) and `--no-session-persistence`; on any
other harness none. Every other word is refused when the preset is set and when a session
starts, `=` forms and short aliases included.

A preset's `systemPrompt` is the text of a Claude Code system prompt (set over the RPC
`_acpmux/presets`, never echoed back). acpmux writes it to `presets/<name>/system.md` next to
its `config.json` (directory 0700, file read-only), records its sha256 (`systemPromptSha256`),
checks the file against that hash at every session start (a mismatch or a missing file refuses
the start) and passes `--system-prompt-file` with that path itself. Set the preset again when
the text changes; the new hash applies to sessions that start after it. Preset names that carry
one use ASCII letters, digits, `-`, `_` and `.`.

A connection from the WebSocket listener (peer daemons, remote clients) is remote-origin:
remote chains build their settings from scratch, so it never starts a session with, sets,
changes or clears a preset that carries `args` or a `systemPrompt`, and a session it created
never spawns with one later.

On Claude Code harnesses, a text block's `cache_control` in `session/prompt` reaches Claude
Code's stream-json input unchanged (other extra block fields are dropped), so a client can
place its own cache breakpoint. Claude Code adds up to three breakpoints of its own and the API
allows four, so a client has room for one.

### Bring your own ACP harness

Every harness is a `harnesses` entry in `~/.acpmux/config.json`. Discovery fills in the ones on
PATH (Claude Code, Codex, OpenCode, pi, oh-my-pi, prime-agent, Gemini, `sr claude proxy`, and
Muse Code through the [cmux-muse-acp](https://github.com/manaflow-ai/cmux-muse-acp) adapter
`muse-acp`, else Muse Code in a terminal tab); a configured entry always wins over a discovered one. A complete entry:

```jsonc
{
  "harnesses": {
    "omp": {
      "argv": ["/Users/me/.local/bin/omp", "acp"],          // any ACP server on stdio
      "family": "omp",                                      // optional: derived from argv when absent
      "env": {"OMP_HOME": "${home}/.omp"},                  // ${cwd}, ${home}, ${model}, ~/ expand
      "models": [                                           // declared catalog, shown ahead of the reported one
        "openai-codex/gpt-5.6-sol",
        {"id": "ollama/qwen3-coder", "name": "Qwen3 Coder (local)"}
      ],
      "model": "openai-codex/gpt-5.6-sol",                  // inline defaults, same as a defaults entry
      "effort": "high",
      "policy": "approve-edits",
      "fallback": "pi",                                     // where a session moves on limit or auth errors
      "description": "oh-my-pi with the local models"
    },
    "gemini-flash": {
      "argv": ["gemini", "--experimental-acp", "--model", "${model}"],   // model as a spawn argument
      "family": "gemini",
      "models": ["gemini-2.5-flash", "gemini-2.5-pro"],
      "model": "gemini-2.5-flash"
    }
  },
  "defaults": {"claude": {"prefer": ["claude-cr", "claude"], "effort": "high"}},
  "presets": {
    "deepseek": {"harness": "deepseek", "model": "deepseek-v4.1-flash", "effort": "high"},
    "opencode-v2-deepseek": {"harness": "opencode-v2", "model": "opencode-go/deepseek-v4.1-flash"}
  }
}
```

`${model}` in argv or env makes the model a spawn parameter: acpmux passes it at start instead
of calling `session/set_model`, and `session set NAME model=…` restarts the process with the
new one. That is how a harness with no model API (prime-agent, or any wrapper script) still
takes `-m NAME/MODEL`. Declared `models` feed the pickers and `daemon models`; the reported
catalog is merged after them. `kind: "claude-stdio"` selects the Claude Code stream-json backend
instead of ACP.

### cmux Codex as the default

`cmux-codex` is our Codex fork with aggressive retries. It runs through the existing
Codex ACP adapter by setting `CODEX_PATH` to the fork executable. It shares Codex's
login and provider configuration; the harness name does not create another model API provider.

Merge this into `~/.acpmux/config.json`, using your installed adapter and fork paths:

```json
{
  "harnesses": {
    "cmux-codex": {
      "argv": ["${home}/.local/share/cmux-acp/current/bin/codex-acp"],
      "family": "codex",
      "env": {"CODEX_PATH": "${home}/.local/cmux-codex/bin/cmux-codex"},
      "description": "cmux Codex with aggressive retries"
    }
  },
  "defaultHarness": "cmux-codex",
  "defaults": {
    "codex": {
      "prefer": ["cmux-codex", "codex"],
      "model": "gpt-6-astra",
      "effort": "high"
    }
  }
}
```

Then `acpmux daemon reload` makes the profile/default available for new sessions.
`acpmux new` uses it by default; `acpmux new -m cmux-codex` chooses it explicitly.
Existing session processes retain their current executable.

The verified fork ([`40be6cca8`](https://github.com/manaflow-ai/codex/commit/40be6cca8004ed0424b35b4610d4bc19598d42f5))
retries transient stream failures without a limit, with a one-second default delay
or the server's requested delay. Remote compaction uses the same unlimited default;
quota-class errors stay terminal. Leave the provider's `stream_max_retries` unset:
an explicit value selects a finite budget (clamped to 100). The retry loop belongs
to the fork, not acpmux's `--retries` flag. Keep `codex-code-mode-host` and
`codex-responses-api-proxy` installed beside the fork executable.

### DeepSeek Harness and OpenCode v2

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/acp/acp/README.md)
runs as `dsh --profile acp`; [OpenCode v2](https://github.com/anomalyco/opencode)
runs as `opencode2 acp`. Both are discovered on PATH. They appear as `deepseek` and
`opencode-v2`. Use `acpmux daemon reload` (or `/reload` in the TUI) after installing
one. The harness picker fetches the current local and peer catalogs whenever it opens.

Install the tested DSH version:

```sh
npm install --global @deepseek-ai/dsh@0.1.5-rc.2
```

For the [OpenCode Go subscription](https://opencode.ai/docs/go/), use Chat Completions at
`https://opencode.ai/zen/go/v1` and the exact model id `deepseek-v4.1-flash`.
The Go key belongs in `~/.dsh/.credentials.yaml` (mode `0600`):

```yaml
version: 1
refs:
  OPENCODE_GO_API_KEY: YOUR_OPENCODE_GO_KEY
records: {}
```

Add this route to `~/.dsh/profiles/acp/cordis.patch.yml`. The profile patch supports
`!!js`; `settings.yaml` does not. acpmux supplies a stable session id, so the Go routing
header stays the same across turns and differs between acpmux sessions. Direct launches
use a process-specific fallback; run one conversation per process with this fallback.

```yaml
- id: acp
  config:
    provider: opencode-go-v41
    model: deepseek-v4.1-flash
- id: llm-pi-ai
  config:
    providers:
      opencode-go-v41:
        displayName: OpenCode Go - DeepSeek V4.1 Flash
        apiKeyEnv: OPENCODE_GO_API_KEY
        api: openai-completions
        baseURL: https://opencode.ai/zen/go/v1
        headers:
          x-opencode-session: !!js process.env.ACPMUX_SESSION_ID || ('dsh-' + process.pid + '-' + Date.now())
          x-opencode-client: dsh
        models:
          - id: deepseek-v4.1-flash
            name: DeepSeek V4.1 Flash
            contextWindow: 1000000
            maxTokens: 384000
            reasoningEfforts: {low: low, high: high, max: max}
            compat:
              supportsStore: false
              supportsDeveloperRole: false
              maxTokensField: max_tokens
              requiresReasoningContentOnAssistantMessages: true
              thinkingFormat: deepseek
```

An existing `llm-pi-ai.providers.opencode-go-v41` section in `~/.dsh/settings.yaml`
overrides the profile patch; remove a static `x-opencode-session` there before using
this configuration. DSH 0.1.5-rc.2 needs this explicit model entry and header.

Optionally merge profiles into `~/.acpmux/config.json` to set defaults or absolute
executable paths (use your actual `dsh` / `opencode2` path if absent from the daemon's PATH):

```json
{
  "harnesses": {
    "deepseek": {
      "argv": ["dsh", "--profile", "acp"],
      "family": "deepseek",
      "model": "opencode-go-v41/deepseek-v4.1-flash",
      "models": [{"id": "opencode-go-v41/deepseek-v4.1-flash", "name": "DeepSeek Harness · V4.1 Flash (OpenCode Go)"}],
      "effort": "high"
    },
    "opencode-v2": {
      "argv": ["opencode2", "acp"],
      "family": "opencode-v2",
      "model": "opencode-go/deepseek-v4.1-flash"
    }
  }
}
```

```sh
acpmux daemon reload
acpmux run -m deepseek "your task"
acpmux run -m opencode-v2 "your task"
```

OpenCode v2 uses the existing OpenCode provider credentials. DSH's ACP model option
values are opaque JSON strings; acpmux flattens their groups and accepts the exact
advertised value, an unambiguous model id, or `provider/model`. DSH exposes reasoning
effort but no modes or native ACP fork/load; acpmux's transcript rehydration handles
reopening sessions when the agent cannot load them.

## Forks and plugins that were dogfooded

Every harness below was run through acpmux end to end (create, prompt, effort, permission flow,
`ls`/`info`/`tail`). Findings as of 2026-09-18:

| Harness | How acpmux runs it | Works | Notes |
| --- | --- | --- | --- |
| [oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`) | discovered as `omp acp`, family `omp` | yes | 60+ providers from `~/.omp/agent/models.yml`; `-e` drives its `thinking` option; delegates file writes to acpmux, so `--policy ask` gates edits. omp 17.3.2 repeats the final text of a first turn (`pearpear`); 18.1.18 does not: upgrade. |
| [prime-agent](https://github.com/PrimeIntellect-ai/prime-agent) | discovered as `prime-agent --mode acp`, family `prime` | yes | One session per process (acpmux does that anyway). No model API over ACP: `-m prime` only; the model comes from `~/.prime/agent/settings.json`, and `-m prime/x` says so. Writes files itself, so `ask` gates only its shell. |
| [oh-my-opencode](https://github.com/opensoft/oh-my-opencode) | OpenCode plugin: `"plugin": ["oh-my-opencode@4.19.4"]` in the project's `.opencode/opencode.json` | yes | Its agents (Sisyphus, Oracle, …) arrive as the `mode` config option, so `session set NAME mode=…` and the TUI `/set` pick them. A user-level `"permission": "allow"` in `opencode.json` means OpenCode never asks; acpmux policies then apply only to what it delegates. |
| [oh-my-codex](https://github.com/Yeachan-Heo/oh-my-codex) (`omx`) | no ACP; Codex is the engine. `omx setup --scope project` writes `<project>/.codex`; run Codex with `CODEX_HOME` there | yes, with two steps | `acpmux preset omx harness=codex 'env.CODEX_HOME=${cwd}/.codex'` then `run -p omx --cwd PROJECT`. The project home needs the user's provider lines (`openai_base_url`, …) and an `auth.json` (a symlink to `~/.codex/auth.json` works; a copy breaks on token rotation). `omx setup --scope user` avoids both. |

Two acpmux changes came out of this. Every ACP harness is told acpmux implements the client
file system (`fs/read_text_file`, `fs/write_text_file`): a harness that delegates writes (omp,
Zed-style agents) has every edit pass through the permission policy and rules, and reads are
refused under `deny-all` or a deny rule. Harnesses that write files themselves (pi, OpenCode,
prime) still gate only what they choose to ask about. And profile, family and preset `env` values
expand `${cwd}`, `${home}`, `${model}` and a leading `~/`, so one preset can point a harness at a
per-project home.

## Peers: every session on every machine, from one Mac

A daemon can mirror other daemons. Add a peer and its sessions appear locally as
`<peer>/<name>`. `ls`, `attach`, `send`, `fork`, `set`, `allow`, and the TUI all work on them; every
request is forwarded over the peer's WebSocket and every event streams back.

The simplest peer is an SSH host, and `host setup` does the whole install from the Mac:

```sh
acpmux host setup HOST                 # scp the binary, write config + launchd plist, start it, add the peer
acpmux host ls                         # connected/offline, remote build, and "outdated" when it lags yours
acpmux host status [HOST]              # each host asked live: reachable, round trip, disk, load, live sessions, build
acpmux host update --all               # push the current binary to every ssh peer and restart it
acpmux host update HOST --if-idle --binary-dir DIR  # push DIR/acpmux-<target>, unless a session there is mid-turn (not counting the one running this)
acpmux host update HOST --keep-newer --binary-dir DIR  # never a move back: a later day's build or one with local changes stays (current)
acpmux ls                              # HOST/session-name next to local sessions
acpmux new -m claude --host HOST "…"   # start a session there; `ensure NAME --host HOST` too
acpmux attach HOST/session-name        # or plain `acpmux attach` for the full sidebar
acpmux session export HOST/name        # the bundle is fetched to ~/.acpmux/bundles/HOST-<id>
```

On a Mac running cmux NEXT, `--group` puts a remote chat in a local sidebar
workspace group:

```sh
acpmux new --host HOST -m codex --group "Remote demo" -d "say hi"
```

The local `cmux agent open` receives the session ID mirrored by the local
daemon; the agent stays on HOST. The group is joined or created, and opening
the workspace may move focus. Add
`--name demo --reuse` when rerunning should reuse the same
session and row; an unnamed launch creates a new session each time. The
invoking Mac needs `cmux` on PATH and the app must use the daemon that mirrors
HOST. A failed sidebar open warns without stopping the agent; retry the
printed `cmux agent open` command. Wrappers executing acpmux on HOST should
omit `--group` remotely and open the returned ID on the controller Mac after
creation. See [remote agents](../../../docs/remote-agents-and-cloud.md) for
native tab commands and connection diagnostics.

`acpmux --version` prints the build id (`git hash+dirty date`), and peers compare it in the
initialize handshake, so a "Method not found" from a peer names the build gap instead of a
missing feature. `host update` skips a peer that already runs the same commit, installs a
binary only once it runs on the peer, keeps the binary it replaces as `~/.local/bin/acpmux.prev`, and puts it back when the restarted daemon does
not answer with the new build. A daemon that runs under a hand-written `acpmux*.service` unit is
moved to the standard `acpmux.service` (its home, socket and drop-ins carried over, agents kept).
A cmux Cloud VM is never updated this way (`cloudMachine`): `cmux link machine update --to-bundled` owns it.
A Linux host that runs `acpmux.service` also gets `acpmux-update.timer` from `host setup` and
`host update`: every 15 minutes it runs `acpmux host self-update`, which downloads the newest
daemon-tested feat-cmux-next build (`cmux-tui/channels/feat-cmux-next.json` on files.cmux.com)
when the installed binary differs, checks its sha256 and updates the daemon the same way, rollback
included. A build pushed by hand is replaced by the channel's at the next run;
`host setup --no-auto-update` (the file `~/.acpmux/no-auto-update`) keeps a host off the timer.
One update of a host runs at a time: the timer, `host update`, `host setup` and `host enroll --fix`
take the host's update lock (a lease in `~/.acpmux`, kept by the update's connection or the timer's
process; it needs `flock` or `perl` on the host), and one that finds it held changes nothing
(`host update`: `updateRunning`). Every step checks the lease on the host first, so an update whose
connection dropped stops (`lockLost`). The updates reach the daemon through the
`ACPMUX_HOME` and `ACPMUX_SOCKET` that `acpmux.service` and its drop-ins set.
`--json` reports each peer's `outcome`: `updated`, `current`, `busy`, `needsBinary`,
`rolledBack` or `failed`. `host setup` needs ssh + scp access and a Mac or Linux box with `launchctl`
(Linux hosts run `acpmux daemon` under whatever supervisor you use). Hosts added by hand still
work: `acpmux host add HOST ssh://HOST` (`ssh://user@host:port` is fine) reads the remote token
over the same ssh access.

Plain WebSocket peers work too, for hosts with a public address or an existing tunnel:

```sh
acpmux host add sandbox-a wss://sandbox-a.example.com:47811 --token "$TOKEN"
```

Everything works on a peered session: `send`, `wait`, `history`, tags, rules, the TUI,
permission prompts, fork, model and mode changes. `Ctrl-t` from a peered session drafts a new
session on that peer, and the `Ctrl-l` picker lists remote harnesses as `HOST/harness`, so
picking one starts the session there. Peers reconnect with backoff, the tunnel included; while
one is down its sessions show `unreachable`, and a purge on either side removes the session
everywhere. Peers are saved in `config.json` under `peers`.

`acpmux host status` (also the hidden `peer status` alias, with `--json`) is the check to run before remote work
and after a peer request fails. It asks every connected peer `_acpmux/host_health` at once,
with 5 s each, and lists this machine first. Each row has:
- whether the peer is reachable, and the round trip (`latencyMs`);
- free and total space on the disk that holds acpmux's home;
- load (1/5/15 minutes) and CPU count;
- live sessions;
- version, build and `outdated`.

An offline peer's row gives its link state and the next command (`acpmux host doctor HOST`).
A peer on an older build that lacks the method shows as reachable, and names
`acpmux host update HOST`. A remote session's `--cwd` and worktrees are on the peer's disk
(`~/.cmux/worktrees/<project>/<name>` there). There is no move from one peer to another:
`session export HOST/name` and `session import DIR` bring a session here.

A daemon needs a working harness. launchd, the app, the Chief and a non-login ssh shell start the
daemon with a bare environment, so every daemon reads the login shell's environment
(`$SHELL -l -i -c env -0`, no terminal, at most 3 s) and passes on only an allow-list of what its
own environment lacks. Every child: PATH (login PATH first), MISE_*, ASDF_*, NVM_*, VOLTA_*,
BUN_INSTALL, HTTPS_PROXY, HTTP_PROXY, ALL_PROXY, NO_PROXY (both cases),
NODE_EXTRA_CA_CERTS, SSL_CERT_FILE, SSL_CERT_DIR. Claude harnesses also: ANTHROPIC_*, CLAUDE_*,
DISABLE_*, *_TELEMETRY; AWS_* only with the person's own CLAUDE_CODE_USE_BEDROCK (a profile's switch unlocks only AWS_PROFILE, AWS_REGION, AWS_DEFAULT_REGION, AWS_CONFIG_FILE, AWS_SHARED_CREDENTIALS_FILE); GOOGLE_*, CLOUDSDK_*, GCLOUD_*, CLOUD_ML_REGION, VERTEX_REGION_* (non-secret ones only from a profile's switch) only
with CLAUDE_CODE_USE_VERTEX. Codex harnesses also: OPENAI_*, CODEX_*. Nothing else (GITHUB_TOKEN,
GH_TOKEN, NPM_TOKEN, ...) unless `loginEnvAllow` in config.json names it (exact names or `PREFIX_*`;
default empty). A daemon started inside a Claude Code session drops that session's `CLAUDE*` and
`ANTHROPIC_*` keys from its agents and gives them the login shell's values instead, within the
same allow-list. Precedence: profile, preset and session env, then the daemon's own environment,
then the login shell's.
`<ACPMUX_HOME>/login-env.json` (0600) caches the result by a fingerprint of the shell's startup
files: non-secret values and the names of secret ones (their values stay in memory), so a start
with a matching cache and no secret to fetch never runs the shell, and agent spawns wait for the
shell (at most 3 s) only when Claude has no sign-in without it. `ACPMUX_LOGIN_ENV=0` turns this
off. Claude Code keeps its login in the macOS keychain, so on a headless Mac without an API proxy
run `claude` once in a terminal and log in. A Claude turn that fails because Claude is not signed
in says what the agent had, how the terminal signs in (the Claude home, keys, settings files,
keychain) and the fix, ending with Claude's own words. A
discovered `claude-cr` or `claude-sr` launcher is checked at daemon start (`--version`) and
dropped, with a log line, when the installed CLI cannot run it; `claude` then has no
fallback instead of failing over into a launcher that dies at once. When a subrouter server is
known, the launcher instead becomes a copy of `claude` routed through that server, but only when
`claude` is acpmux's own adapter: `claude-sr` never becomes an ACP adapter, and the pool never
falls back onto one.

### Messages to other sessions: the outbox

`acpmux send --no-wait NAME` is how one session (or a person, or a script) messages another,
here or on any peer, and it acks within a second whatever the target is doing:

1. **Enqueue.** The CLI sends `_acpmux/send_queue {request}` to its own daemon: the
   `session/prompt` params it would have sent, with a prompt id. The daemon checks that the
   target is a session here, one a peer lists, or one on a peer that is down now, records the
   delivery in `outbox.json` beside the sessions, and answers `{deliveryId, target, status}`.
   Only the unix socket may queue.
2. **Ack.** That answer is the ack: the message is the daemon's to deliver from then on, across
   a restart too. The CLI waits half a second more for a target that takes it at once, so a local
   send still prints `steered` or `queued`.
3. **Deliver.** In the background the daemon sends the prompt over its own connection, as the
   sender's session when the sender proved one, so every rule of a direct send applies; a peer's
   session is forwarded as usual. An attempt ends on the target's `_acpmux/prompt_accepted`,
   which a peer now passes back as soon as it takes the prompt, not when its turn ends.
4. **Retry and dedupe.** A connection error, a peer that is down and a target that does not
   answer within 120 s are tried again after 2 s, 5 s, 10 s, 30 s, 1, 2, 5, 10 and 15 minutes (about
   34 minutes in all), always with the same prompt id and `resend`, so a target that took an
   earlier attempt answers with that one and never runs it twice. Sending the same prompt id
   again returns the first delivery. A refusal (no such session, the folder's trust, a bad
   prompt, a full agent pair) fails the delivery at once. A paused agent pair leaves it `held`:
   the target's daemon runs it when the person resumes the pair, so it is never sent again from
   here. `--no-wait` prints a refusal or a hold that comes within half a second as its error, as
   a direct send did.
5. **Status.** `acpmux send --status ID` (`_acpmux/send_status {deliveryId, waitMs?}`) reads it.
   Delivered, held and failed deliveries are kept for a day.

Before this, a `--no-wait` send to a peer waited for the peer's whole turn: the forwarded
`session/prompt` answers only when the target's turn (or a steer's step) ends, and the peer's
`_acpmux/prompt_accepted` was dropped on the way back.

## Claude Code: native stdio backend

Claude Code sessions run over Claude's own headless protocol, not ACP:
`claude -p --input-format stream-json --output-format stream-json`. One `claude` process per
session stays alive until you stop it. acpmux translates the stream into the same events the
TUI, web page, and peers already understand, so nothing changes for the user.

What this gives over the ACP adapter: none of the adapter's injected MCP servers or hooks, real permission
prompts with Claude's own options, `AskUserQuestion` and plan approval answered from the TUI
or web page, model and mode changes mid-session, exact resume with `--resume`, fork with
`--fork-session`, and background Bash tasks that live as long as the session because the
process never exits between turns.

```json
"claude": { "kind": "claude-stdio", "argv": ["claude", "--model", "opus[1m]"] }
```

Everything after `claude` in `argv` is passed through, so `--settings`, `--mcp-config`,
`--allowedTools`, `--append-system-prompt`, and `--permission-mode` all work. `acpmux harnesses`
picks this backend automatically when `claude` is on PATH. Interrupt uses Claude's
`control_request` `interrupt`; the interrupted turn ends with `stopReason: cancelled` and the
process keeps running.

### cmux tools in every session

Every local session gets cmux's own agent tools: the `cmux-cua` MCP server (Computer Use)
when `cmux-cua` sits next to the acpmux binary, the `cmux` MCP server with the browser REPL
tools when `cmux.json` sets `"mcp": {"enabled": true}`, and, for Claude Code, a session-only
plugin `cmux` with the skills `cmux:cmux-browser` and `cmux:cmux-cua`. Set
`ACPMUX_AGENT_TOOLS=0` in the daemon's environment to turn all of them off, or in one
profile's or preset's `env` to turn them off for that profile only. A Claude profile whose
`argv` has `--strict-mcp-config` also gets none of them, so it keeps exactly the servers its
own `--mcp-config` names.

Every local session also gets the `acpmux` MCP server (`acpmux acpmux-mcp`, `acpmux_mcp.rs`),
so an agent messages another lane or session with a tool call instead of piping text into
`acpmux send --no-wait` in a shell. Behind the `cmux` server its tools are:

- `acpmux_send {to, text, steer?}`: message a session by name, id or `host/name`. Like
  `acpmux send --no-wait`, it hands the message to this daemon's outbox (`_acpmux/send_queue`),
  which delivers it as this session and retries a slow target or a peer that is down. It returns
  the `promptId` and delivery id once the delivery settles (steered in, queued, or a new turn),
  or after 5 s with the message on its way; it never waits for the reply. `steer` defaults to true.
- `acpmux_ls {status?}`: one line per session on this machine and its peers.
- `acpmux_last {name, count?}`: a session's last replies.
- `acpmux_info {name}`: a session's state, as `acpmux session info`.

Each tool is the request the agent's own `acpmux` CLI makes, on this daemon's socket, with the
session's caller token. The tools can do nothing that CLI can't, and the receiver's chat
records a sent message as this agent's (`session_message`), never as the person's. A
remote-origin session gets none of cmux's tools, this server included. The agent pane draws
an `acpmux_send` call as the collapsed "Sent to NAME" message row.

Stopping a session kills the agent's whole process group, so background shells the agent
started stop with it. Resume afterwards is exact, but the agent no longer remembers those
processes.

## CodeRouter route (configured only)

`coderouterClaudeRoute` in `config.json` (or `ACPMUX_CODEROUTER_CLAUDE_ROUTE` in the daemon or
login environment, which wins) names a CodeRouter CLI subcommand that runs Claude Code through
a CodeRouter route. When it is set and `coderouter` (else `cr`) is on PATH, acpmux adds a
`claude-cr` profile (`coderouter <route>`, kind `claude-stdio`), makes it the first `claude`
preference and the direct `claude` fallback. Unset, there is no `claude-cr`. The CLI uses its
own login; acpmux never reads or copies a credential.

## Subrouter: Claude across many accounts (explicit choice only)

[Subrouter](https://github.com/manaflow-ai/subrouter) is a local proxy that spreads Claude and
Codex traffic across subscription accounts and fails over when one hits its limit. When `sr`
is installed, acpmux discovers a `claude-sr` profile that launches Claude through the pool
(`sr claude proxy`, which accepts acpmux's stream-json flags, `--session-id` and `--resume`).
It is used only when named, or in a `prefer` or `fallback` the user writes.

- `acpmux run -m claude-sr "…"` always uses the pool; the pool picks the account with the
  most quota and keeps the conversation sticky to it.
- A session whose account reports a usage or rate limit mid-turn is moved onto its profile's
  `fallback` automatically: the agent process is replaced by one that resumes the same Claude
  session, the prompt runs once more, and a `failover {from, to, reason}` event is logged.
- Any profile can name a `fallback` in `~/.acpmux/config.json`; the same rule applies to
  every harness, keyed on the error text (`reached your … limit`, `rate limit`, `quota`,
  `429`, `out of credits`).


Harnesses found on PATH join the configured ones at every start: `claude`, `codex-acp`,
`gemini`, `opencode`, and `pi-acp` (the ACP adapter for pi: `bun add -g pi-acp`). Entries in
`~/.acpmux/config.json` always win over discovery.

`~/.acpmux/config.json` (override the directory with `ACPMUX_HOME`):

```json
{
  "harnesses": {
    "codex":  { "argv": ["codex-acp"] },
    "claude": { "argv": ["claude-agent-acp"], "env": {"ANTHROPIC_API_KEY": "..."} }
  },
  "defaultHarness": "codex",
  "permissionPolicy": "ask",
  "store": { "mode": "local", "segmentBytes": 8388608 },
  "websocket": { "listen": "127.0.0.1:47811", "token": "change-me" },
  "peers": { "sandbox-a": { "url": "wss://sandbox-a.example.com:47811", "token": "..." } }
}
```

When no config exists, harnesses are imported from `~/.acpx/config.json` (its `agents` block) and from adapters on PATH. `claude`, `claude-cr` and `claude-sr` are reserved for acpmux's own Claude Code adapter (`claude-stdio`): when `claude` or `sr` is on PATH (or a CodeRouter route is configured), an `~/.acpx` entry of that name is ignored. Only `config.json` rebinds them.

- `permissionPolicy`: `ask` routes `session/request_permission` to attached clients and waits.
  `approve-all`, `approve-reads`, `approve-edits` (reads and edits auto, shell asks), and `deny-all` answer locally. Per-session override with
  `acpmux set NAME policy=...`. A session an agent starts from inside its own session (`acpmux new|run`, a local `dispatch`,
  `--parent`, the `start_session` tool), with no policy or mode of its own, inherits that session's policy (or a narrower
  family default) and mode (on another family, the same level: full access, asking, or the harness's own), never wider;
  a start with no proven session (no caller token) is unchanged (`hub/start_mode.rs`, "Inherit").
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
`_meta.acpmux: {steer: true, promptId}`. Its response still comes at the end of the turn and adds
`_meta.acpmux: {promptId, turnId, turnSeq}`; the prompting connection first gets
`_acpmux/prompt_accepted {sessionId, promptId, turnId, queued, position?}` as soon as the prompt
is recorded. `session/cancel` works as a notification or as a request (answered `{}`). Every live
`session/update` keeps the agent's `_meta` and adds `_meta.acpmux: {seq, at, kind}`.

Extensions:

| Method | Purpose |
| --- | --- |
| `_acpmux/status`, `_acpmux/harnesses`, `_acpmux/sessions` | Daemon and fleet state; status also reports `ready`, `loginEnv`, `listen` and `capabilities`. |
| `_acpmux/attach {sessionId, afterSeq?, beforeSeq?, limit?, maxBytes?, kinds?, eventStream?}` | Subscribe and get the session detail, a page of events, and `hasMore`. |
| `_acpmux/detach`, `_acpmux/watch {enabled}` | Unsubscribe; or receive `_acpmux/session_changed` for every session. |
| `_acpmux/typing {sessionId, on}` | A person in an attached chat starts or stops typing ([presence](#chat-presence)). At most 2 calls a second per connection (`typing.rate_limited`); an `on` lapses after 8 s. |
| `_acpmux/harness/inventory/watch {enabled}` | Local socket only: [sanitized cached inventory snapshots](docs/inventory-watch.md), with monotonic per-run revisions and no health checks or CLI execution. Requires `harnessInventoryWatch`. |
| `_acpmux/events {sessionId, afterSeq?, beforeSeq?, limit?, maxBytes?, kinds?}` | Page through the log, forwards or backwards, with `hasMore`. A page ends at `maxBytes` of JSON (default 1 MiB, at most 4 MiB). |
| `_acpmux/attachment {sessionId, id}` | An image a prompt of the session sent, as `{mimeType, data}` (base64). `user_message` names a prompt's images as `images: [{id, mimeType, name?}]`; the bytes are kept once by SHA-256 under `<ACPMUX_HOME>/attachments`. Only an id the session's own log names is read. |
| `_acpmux/info`, `_acpmux/rename`, `_acpmux/kill {purge}`, `_acpmux/set_policy` | Session control. |
| `_acpmux/queue_remove {promptId}` | Withdraw a queued prompt before its turn starts: `removed` is false once it started. Its `session/prompt` answers `cancelled` with `_meta.acpmux.withdrawn`, and the log records `queue_removed`. |
| `_acpmux/permission_respond {sessionId, permissionId, optionId}` | Answer a request announced by `_acpmux/permission_pending`. Any client may deny or cancel; only the cmux app's connection (it presents the app's per-launch person key) may allow. Others get `permission.person_required` ("approve this on the Mac app") and the request stays pending. The same rule guards every grant that widens what runs without asking (policy, rules, modes, defaults). |
| `_acpmux/export {sessionId, dest}`, `_acpmux/import {path, name}` | Bundles. |
| `_acpmux/file_put {sessionId, fileName, data}` | Save a file the person dropped into the chat (base64, at most 10 MiB) on the machine that runs it, owner-only under `<ACPMUX_HOME>/uploads/<sessionId>/<random>/<fileName>`, and answer `{path}`. A peer's chat is forwarded there (only to a peer whose `initialize` features list `filePut`; else `Method not found`, `data.reason: "filePut.unsupported"`). Not from a Web connection (`filePut.remote`). Nothing deletes uploads yet. |
| `_acpmux/media_open {sessionId, path}` | Open an image or video the chat names, on the machine that runs it, and answer `{handle, size, mimeType, identity}`. Relative paths start in the chat folder; absolute paths may be inside that folder, `/tmp`, the user's home, or the chat uploads. Every component is opened with `O_NOFOLLOW`, the opened file must be a regular file with one link, inside those roots and not a dot name, key file or `~/Library` path, and its bytes must be png, jpeg, gif or webp (at most 10 MiB) or mp4, mov, m4v or webm (at most 200 MiB). At most 8 handles per connection, each closed after 2 minutes idle and all at disconnect. A peer chat goes to the peer only when its `initialize` features list `mediaRead` (else `mediaRead.unsupported`); never from a Web connection (`mediaRead.remote`). |
| `_acpmux/media_range {sessionId, handle, offset, length}` | Read 1 to 6 MiB of an open handle and answer `{offset, size, identity, data}` (base64), `size` and `identity` repeating the open. A file changed since the open (device, inode, size or mtime) is refused (`media.changed`) and its handle closed; the range that reaches the end closes it too. |
| `_acpmux/peers`, `_acpmux/peer_add {name, url, token}`, `_acpmux/peer_remove {name}` | Mirror remote daemons. |
| `_acpmux/shutdown` | Stop the daemon. |

Notifications to attached clients: `session/update` (standard), `_acpmux/event` (mux-internal
records such as `user_message`, `status`, `turn_result`, `permission_request`),
`_acpmux/permission_pending`. Watchers get `_acpmux/session_changed {sessionId, kind,
recordKind, seq, session}` (kind `queue` for queue changes, `permission_resolved` for automatic
approvals) and `_acpmux/permission_pending` with `via: "watch"` for sessions they are not
attached to.

<a id="chat-presence"></a>Chat presence (chat multiplayer, `hub/presence.rs`): attached
connections hear `_acpmux/presence {sessionId, participants: [{id, name, devices, viewing,
typing}]}` on every change, and `_acpmux/attach` answers the same object as `presence`. An entry
is kept per connection and author: `_acpmux/view` and `_acpmux/typing` name their person in
`_meta.acpmux.author {id, name, login?, node?}`, which only the unix socket and a peer daemon
forwarding for its own unix socket or app may send (`author.origin_refused` otherwise); a caller
with no author is `owner`, and a visible attach is the owner viewing. A view with an author
changes only presence, never `unread`, so a link that carries other people attaches with
`visible: false` and names each of them in `_acpmux/view`. An entry goes when it neither views
nor types, when its connection detaches or closes. At most 32 people besides the owner per chat
(`presence.full`).
Presence is never written to the log, `_acpmux/events` or an export. Only a daemon's own chats
have it: a peer daemon's link carries all of that daemon's clients, so it makes no entry, its
`_acpmux/typing` and authored `_acpmux/view` answer `presence.peer_unsupported`, and a chat that
lives on a peer attaches with no participants.

Paging for chat clients: `beforeSeq` returns the newest `limit` records before it, oldest first,
and `hasMore` says older ones exist. `kinds` filters records before `limit` counts them:
`["transcript"]` keeps agent updates a chat renders plus `user_message`, `queued`, `dequeued`, `queue_removed`,
`turn_started`, `turn_result`, permissions and `message_superseded`, and drops raw wire records,
responses and `.replay` records. Categories `mux`, `wire` and `all`, or exact record kinds, also
work. `eventStream: true` on attach delivers every live record (filtered by `kinds`) as
`_acpmux/event`, with agent notifications nested in `msg`, instead of `session/update`.

Turns: `queued`, `dequeued`, `queue_removed`, `user_message`, `turn_started`, `turn_end` and `turn_result`
carry `turnId` (and `promptId`); `turn_result.turnSeq` is the seq of `turn_started`. A failed
turn's `turn_result` has `errorText` and `errorCode`, and `errorChunkSeqs` when the harness had
streamed that same text as an ordinary message. A terminal error that Codex reports in-band
(`_meta.codex.error` without `willRetry`) fails the turn even when Codex then ends it normally.
Session summaries carry `lastTurn`; `acpmux wait` exits 1 when a resolved session's last turn failed, and
`--print` then prints that turn's error (`error` under `--json`), never the reply of the turn
before it, with the automatic retry that waits, if one does (`retry`: what it waits out and when
it runs). When Codex abandons a partial answer after a
dropped stream and redelivers it, acpmux records `message_superseded {oldMessageId,
newMessageId}` before the redelivery. Other harnesses send no such signal.

The daemon binds its socket and `--listen` address (`127.0.0.1:0` picks a free port) before it
imports the login shell environment, so `_acpmux/status` answers at once; session creation waits
for the import only when it must (see above), at most 3 s. `daemon run --ready-fd N` writes `{"ready":true,"pid","socket","listen","webUrl"}`
to descriptor N when bound. SIGTERM (even when the launcher left it blocked) sends SIGTERM to every agent's process
group, SIGKILL after 2 s, saves sessions and exits within 5 s.
`acpmux daemon schema` prints the full RPC schema.

`initialize` (`_meta.acpmux.capabilities`) and `_acpmux/status` (`capabilities`) list the
protocol surfaces this build serves by stable id, as cmux-tui's `identify` does: `acpmux-v1` for
the base a chat client needs, then one id per surface such as `queue-edit-v1` or
`permission-groups-v1` (`src/capabilities.rs` names the methods each covers). An id never
changes meaning; a changed contract gets a new one. `acpmux capabilities --json` prints the same
list with no daemon running, which the cmux app bundle records for its web pages.

Any other method that names a `sessionId` is forwarded to the agent unchanged, so vendor
extensions keep working.

### Typed errors

An error a client sees can say what kind of failure it is and what to do, in three keys added
beside what was there: on a request's JSON-RPC error `data`, on the `turn_error` and `turn_result`
records of a failed turn, and so on the session's `lastTurn`. The error's own message (`error`,
`errorText`) stays a whole sentence, so a client that reads only that still reads well.

- `errorKind`: `disk.full` (a write hit a full disk or quota), `disk.low` (`daemon status`:
  under `diskLowBytes`, 1 GiB by default, free on acpmux's disk), `peer.unreachable` (the peer
  did not answer; the request was not sent), `daemon.restarting` (the daemon is
  shutting down), `spawn.failed` (the harness's program or folder is missing) or `agent.exited`
  (the agent's process ended mid-turn). A client treats a kind it does not know as a plain error.
- `recovery`: one sentence with the action, e.g. "The disk is full. Free space on the disk that
  holds /home/me/.acpmux: 0.9 GB free of 252 GB. acpmux's chats in /home/me/.acpmux/sessions
  use 3.0 GB; `acpmux session stop <session> --purge` removes a chat you no longer need."
  acpmux never deletes anything itself.
- `details`: only the keys that apply: `path`, `freeBytes`, `totalBytes`, `peer` (its name in
  `acpmux host ls`), `lastSeenAt` (RFC 3339), `binary`, `cwd`, `exitCode`,
  `signal`, `queued` (the message waits in the outbox and goes when the peer or daemon is back),
  `retryAfterMs`. The schema is `ErrorDetails` in `spec/acpmux-protocol.json`.

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

## Credits

acpmux's harness support follows the design of [t3code](https://github.com/pingdotgg/t3code)
by pingdotgg (MIT License, Copyright (c) 2026 T3 Tools Inc.): the set of coding agents it
supports, how each one is started, and how sign-in, models, permissions and resume map onto
one session. Files that adapt t3code code or data keep its copyright line in their header.
The full license text is in the "t3code (agent harness support)" section of the repository's
`THIRD_PARTY_LICENSES.md`.
