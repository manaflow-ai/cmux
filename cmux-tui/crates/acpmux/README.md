# acpmux

tmux for coding-agent harnesses. A Rust daemon keeps [Agent Client Protocol](https://agentclientprotocol.com)
agents (Codex, Claude Code, Gemini, OpenCode, Pi, ...) alive as named sessions, records every
wire message, and lets any number of clients attach, prompt, steer, cancel, fork, and change
model or mode. It speaks plain ACP to its clients plus a small `_acpmux/*` extension, so the
CLI, the TUI, a web dashboard, or a Cloudflare Durable Object all use the same protocol.

acpmux never makes outbound calls to a control plane. Something that wants to control it
connects to it.

## Build

```sh
cd cmux-tui
cargo build --release -p acpmux
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
of the session you were on; change them with `/harness NAME`, `/cwd PATH`, `/policy P` before
sending. The first Enter creates the session with that message. Esc on an empty draft discards
it. `/form` opens the older field-by-field form instead. The bottom line of the TUI shows
the web dashboard URL.

```sh
acpmux web                           # print the dashboard URL and open it in the browser
acpmux new -m codex -n backend-review   # scripted: create a session and open the TUI on it
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

A WebSocket connection other than the app's own pane (the dashboard, a paired or relayed
device, a peer daemon) works only inside folders that are known projects (the cwds of local
sessions) or listed in `webRoots`, and only in modes that ask before they act: the reviewed
per-harness table in `src/server/remote_guard.rs` plus what `webAskingModes` adds, for example
`"webAskingModes": {"myharness": ["ask"]}`. Both live in `config.json` and are never written over
a WebSocket. **Warning: a mode that you add to `webAskingModes` lets paired devices start that
mode without a per-action prompt.** See `plans/cmux-next/acp-remote-guard.md`.

## CLI

Five everyday commands, three groups for the rest:

| Command | What it does |
| --- | --- |
| `acpmux` | Open the TUI. Starts the daemon if needed. |
| `new [-m harness[/model]] [-n name] [--cwd dir] [--policy p] [prompt]` | Create a session. Opens the TUI unless `-d`. |
| `send NAME "text" [--steer] [--no-wait] [-q]` | Prompt and stream the reply. |
| `ls` | Sessions on every host, as `host/name` for remote ones. |
| `attach [NAME] [--plain]` | TUI on one session, or a plain text stream. |
| `web [--no-open] [--rotate-token]` | Print the dashboard URL and open it; `--rotate-token` replaces the token first. |
| `host setup HOST` / `host update [--all]` / `host add NAME URL` / `host ls` / `host rm NAME` | Remote daemons. `setup` installs over ssh; URL is `ssh://host`, `ws://…`, or `wss://…`. |
| `session info\|cancel\|stop\|rename\|fork\|set\|allow\|deny\|export\|import\|tail NAME …` | Everything about one session. |
| `daemon run\|status\|shutdown\|config\|harnesses\|reload\|models\|schema` | The daemon itself. |
| `daemon shutdown [--keep-agents]` | Stop the daemon and every agent host it owns; exits 0 only when none is left, and names any host that survives SIGKILL. `--keep-agents` leaves the user sessions' hosts running for the next daemon. |

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

```
acpmux run -m codex --cwd ~/proj "fix the failing test"      # new session, send, print only the reply
acpmux exec -m claude "one-shot"                              # same, and the session is deleted afterwards
acpmux --json run -m claude --policy approve-all "..."       # {"sessionId","name","reply","stopReason","permissions",…}
acpmux ensure NAME -m codex --cwd DIR                         # the session if it exists, else create it
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
acpmux compare -m claude -m codex/gpt-5.5 "prompt"                    # one temporary session per harness, run one after another
acpmux guide                                                  # the agent guide (also --guide, --skill); acpmux daemon schema prints the RPC surface
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
with `acpmux harness doctor <id>` (also `cmux harness …`). Schema, secrets, terminal harnesses,
folder profiles and the ACP adapter guide: [docs/add-your-harness.md](../../../docs/add-your-harness.md).

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
PATH (Claude Code, Codex, OpenCode, pi, oh-my-pi, prime-agent, Gemini, `sr claude proxy`); a
configured entry always wins over a discovered one. A complete entry:

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
acpmux host update --all               # push the current binary to every ssh peer and restart it
acpmux ls                              # HOST/session-name next to local sessions
acpmux new -m claude --host HOST "…"   # start a session there; `ensure NAME --host HOST` too
acpmux attach HOST/session-name        # or plain `acpmux attach` for the full sidebar
acpmux session export HOST/name        # the bundle is fetched to ~/.acpmux/bundles/HOST-<id>
```

`acpmux --version` prints the build id (`git hash+dirty date`), and peers compare it in the
initialize handshake, so a "Method not found" from a peer names the build gap instead of a
missing feature. `host setup` needs ssh + scp access and a Mac or Linux box with `launchctl`
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

A remote daemon needs a working harness. launchd starts the daemon with a bare environment, so
the daemon reads the login shell's environment once at start (`zsh -lic env`) and fills in
what launchd left out: PATH, `ANTHROPIC_*` proxies, tool settings. The same `claude` that works
in an ssh shell then works under the daemon. `ACPMUX_LOGIN_ENV=0` in the plist turns this off,
`=1` forces it for a daemon started by hand. Claude Code keeps its login in the macOS keychain,
so on a headless Mac without an API proxy run `claude` once in a terminal and log in. A
discovered `claude-cr` or `claude-sr` launcher is checked at daemon start (`--version`) and
dropped, with a log line, when the installed CLI cannot run it; `claude` then has no
fallback instead of failing over into a launcher that dies at once. When a subrouter server is
known, the launcher instead becomes a copy of `claude` routed through that server, but only when
`claude` is acpmux's own adapter: `claude-sr` never becomes an ACP adapter, and the pool never
falls back onto one.

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
`_meta.acpmux: {steer: true, promptId}`. Its response still comes at the end of the turn and adds
`_meta.acpmux: {promptId, turnId, turnSeq}`; the prompting connection first gets
`_acpmux/prompt_accepted {sessionId, promptId, turnId, queued, position?}` as soon as the prompt
is recorded. `session/cancel` works as a notification or as a request (answered `{}`). Every live
`session/update` keeps the agent's `_meta` and adds `_meta.acpmux: {seq, at, kind}`.

Extensions:

| Method | Purpose |
| --- | --- |
| `_acpmux/status`, `_acpmux/harnesses`, `_acpmux/sessions` | Daemon and fleet state; status also reports `ready`, `loginEnv` and `listen`. |
| `_acpmux/attach {sessionId, afterSeq?, beforeSeq?, limit?, kinds?, eventStream?}` | Subscribe and get the session detail, a page of events, and `hasMore`. |
| `_acpmux/detach`, `_acpmux/watch {enabled}` | Unsubscribe; or receive `_acpmux/session_changed` for every session. |
| `_acpmux/events {sessionId, afterSeq?, beforeSeq?, limit?, kinds?}` | Page through the log, forwards or backwards, with `hasMore`. |
| `_acpmux/info`, `_acpmux/rename`, `_acpmux/kill {purge}`, `_acpmux/set_policy` | Session control. |
| `_acpmux/permission_respond {sessionId, permissionId, optionId}` | Answer a request announced by `_acpmux/permission_pending`. |
| `_acpmux/export {sessionId, dest}`, `_acpmux/import {path, name}` | Bundles. |
| `_acpmux/peers`, `_acpmux/peer_add {name, url, token}`, `_acpmux/peer_remove {name}` | Mirror remote daemons. |
| `_acpmux/shutdown` | Stop the daemon. |

Notifications to attached clients: `session/update` (standard), `_acpmux/event` (mux-internal
records such as `user_message`, `status`, `turn_result`, `permission_request`),
`_acpmux/permission_pending`. Watchers get `_acpmux/session_changed {sessionId, kind,
recordKind, seq, session}` (kind `queue` for queue changes, `permission_resolved` for automatic
approvals) and `_acpmux/permission_pending` with `via: "watch"` for sessions they are not
attached to.

Paging for chat clients: `beforeSeq` returns the newest `limit` records before it, oldest first,
and `hasMore` says older ones exist. `kinds` filters records before `limit` counts them:
`["transcript"]` keeps agent updates a chat renders plus `user_message`, `queued`, `dequeued`,
`turn_started`, `turn_result`, permissions and `message_superseded`, and drops raw wire records,
responses and `.replay` records. Categories `mux`, `wire` and `all`, or exact record kinds, also
work. `eventStream: true` on attach delivers every live record (filtered by `kinds`) as
`_acpmux/event`, with agent notifications nested in `msg`, instead of `session/update`.

Turns: `queued`, `dequeued`, `user_message`, `turn_started`, `turn_end` and `turn_result`
carry `turnId` (and `promptId`); `turn_result.turnSeq` is the seq of `turn_started`. A failed
turn's `turn_result` has `errorText` and `errorCode`, and `errorChunkSeqs` when the harness had
streamed that same text as an ordinary message. A terminal error that Codex reports in-band
(`_meta.codex.error` without `willRetry`) fails the turn even when Codex then ends it normally.
Session summaries carry `lastTurn`; `acpmux wait` exits 1 when a resolved session's last turn failed. When Codex abandons a partial answer after a
dropped stream and redelivers it, acpmux records `message_superseded {oldMessageId,
newMessageId}` before the redelivery. Other harnesses send no such signal.

The daemon binds its socket and `--listen` address (`127.0.0.1:0` picks a free port) before it
imports the login shell environment, so `_acpmux/status` answers at once; session creation waits
for the import. `daemon run --ready-fd N` writes `{"ready":true,"pid","socket","listen","webUrl"}`
to descriptor N when bound. SIGTERM (even when the launcher left it blocked) sends SIGTERM to every agent's process
group, SIGKILL after 2 s, saves sessions and exits within 5 s.
`acpmux daemon schema` prints the full RPC schema.

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
