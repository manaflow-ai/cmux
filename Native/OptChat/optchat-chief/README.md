# optchat-chief

An OptChat Chief for cmux-next Home. It keeps the brain-host contract of
`mux/host` (so the app needs no changes) and replaces the long-lived `mux`
acpmux session with the turn loop of Victor Taelin's OptChat spec: every human
message is logged into one endless OptChat memory, and every turn is a fresh
model call that reads the memory's view (about 128 KB of one-line summaries of
the whole chat) plus the new messages. The compactor that builds the summaries
runs inside the host: on the team subrouter each summary is one short-lived,
deny-all acpmux session of the normal harness (claude-sr), see
[Compactor routes](#compactor-routes).

Two engines run a turn (`OPTCHAT_CHIEF_ENGINE`):

- `native`: the host's own Messages API loop with `bash`, the text
  editor, `zoom` and `date`. It is the engine that keeps sections 7 and 8
  whole: three cache breakpoints in the view plus the request end, model
  output resent verbatim and tool results capped at CAP.
- `acpmux` (default): the Chief on local ACP only. Each turn is a fresh
  acpmux session of the Chief's harness, named `optchat-<home id>-<first
  id>`, and each summary is one too (see [Harnesses and cache
  layout](#harnesses-and-cache-layout)); no Messages API is called. The
  harness is one setting (`OPTCHAT_CHIEF_HARNESS`). By default it is
  acpmux's own Claude Code adapter (`claude_stdio`): `claude-cr` when acpmux
  has a configured CodeRouter route (`coderouterClaudeRoute`), else `claude`,
  the user's own login. claude-sr (the subrouter pool) only when set; codex
  or any acpmux harness also work.
  Claude Code's Task/Agent subagents are denied (their steps would be
  logged as the Chief's); `chief agents` starts agents instead. So are
  AskUserQuestion, EnterPlanMode and ExitPlanMode: acpmux keeps those for a
  human under every policy, and nobody answers them in a turn.

A human message sent while a turn works interrupts it at once, on both
engines, even mid-thinking and even when it only says "thanks" (decision
2026-10-04); a tool call already running finishes first. The native engine
drops the streaming step at its next streamed event (its thinking and its
unfinished text are not logged or resent), logs the message as `user` and
calls the model again with it, after the running tool's result when there is
one. The acpmux engine waits until no tool call of the turn is running
(Claude Code's interrupt would abort it), then sends `session/cancel`, again
every second until the turn ends (a cancel that reaches acpmux before the
prompt is lost); the next fresh turn answers with the view of everything the
stopped turn did. That turn waits for settle like any turn: section 6 (no
call sees an unsummarized line) makes it wait until the stopped turn's steps
and the new message have their level-0 lines, usually a few node builds.
Text the stopped turn had streamed before the interrupt is logged as `talk`
on the acpmux engine (acpmux does not say whether a reply was finished) and
dropped on the native engine. MASTER says this instead of "reach you between
tool calls".

## Pure Rust over ACP

The Chief's own path is Rust end to end, checked 2026-10-05:

```
cmux-next app (Swift) --starts--> optchat-chief host (Rust)
optchat-chief --JSON-RPC over $ACPMUX_SOCKET--> acpmux daemon (Rust, cmux-tui/crates/acpmux)
acpmux --claude_stdio (Rust adapter)--> sr claude proxy (native subrouter client) --> claude -p (Node)
acpmux --codex harness--> codex-acp (Rust)
optchat-chief --cmux-sdk (Rust)--> session daemon (Rust); --tools.sock--> optchat-chief mcp (Rust)
```

No TypeScript or Node runs in our code on this path: turns, the compactor,
`spawn`/`tell`, the memory tools and the trace are this crate. The agent CLI
itself may be Node (Claude Code is). Two non-Rust hops remain and are not
TypeScript: `$MUX_HOME/optchat/bin/chief` is a 3-line `/bin/sh` launcher that
`exec`s this binary with the host's env baked in, and the agent tab that shows
a subagent's chat in cmux is the app's React page (UI only; it attaches to the
acpmux session, it is not on the model path). `mux/host` (TypeScript, Bun) is
not used when the app runs the bundled `optchat-chief`.

## Subagents (section 9)

The Chief's tools are `zoom`, `date`, `spawn(tasks)` and `tell(id, message)`,
all served by the host on `optchat/tools.sock` (the `optchat` MCP server on a
Claude harness, `chief spawn|tell|zoom|date` on any other).

- `spawn` waits for settle, renders the view, and starts one acpmux session per
  task on `OPTCHAT_SUBAGENT_HARNESS` (default the Chief's), named
  `optchat-sub-<home id>-a<N>`, in the `cwd` it was given (`~` is the host's
  home; a directory that does not exist on the host is reported and
  `optchat/subagent/` is used, which is also the default), with the required preset
  `optchat-sub-<home id>`. Tags: `mux.parent=optchat-chief:<home id>`,
  `optchat.spawn=s<N>`, `optchat.subagent=a<N>`; never `cmux.chief`. It answers
  the ids at once (ids are unique per home, kept in host.json).
- First message: the view at spawn time (one block per cached piece), then
  `Your task:\n\n<task>`. System prompt: section 9's subagent prompt (agent
  renamed Chief), VIEW_DOC, a short cmux section, then the user's AGENTS.md
  (the preset's `systemPrompt` on Claude; CLAUDE.md when acpmux takes none;
  AGENTS.md on other harnesses).
- `zoom("a<N>")` (`chief zoom a<N> [AT]`) gives a subagent's whole chat from
  its acpmux session, one `i|kind: text` line per entry (its task and later
  prompts as `user`, replies `talk`, tool calls `tool`, results `echo`; never
  the view it got), in pages of 30,000 characters that say where to go on.
  Every report ends with `Full chat: zoom("a<N>")`. Subagents may zoom a
  subagent too.
- Subagents get `zoom` and `date` only (`optchat-chief mcp --role subagent`;
  `chief` refuses spawn/tell under `OPTCHAT_SUBAGENT=1`, and the socket refuses
  them from a subagent). Their tool calls stay in their own session.
- Each subagent gets its own cmux workspace named `a<N> · <task>` whose
  selected tab is the agent chat on the SAME acpmux session (app action
  `agent.openSessionWorkspace` over `CMUX_SOCKET_PATH`, with a key chosen by the
  host). The user watches it live and can write to it; that input is a normal
  user message to the subagent and shows in the trace as `subagent.input`. When
  the subagent finishes, the workspace is renamed `✓ a<N> · <task>` (daemon
  `rename-workspace` by key); it runs again, the mark goes. Closing the
  workspace or tab only detaches; the session is never killed by the host.
  `OPTCHAT_SUBAGENT_WORKSPACES=0` turns workspaces off;
  `OPTCHAT_SUBAGENT_ON_FINISH=close` closes a finished subagent's workspace
  (daemon `close-workspace` by key, into the closed history) instead of the
  done mark.
- A host with no app (`CMUX_SOCKET_PATH` unset) and a cloud install (the
  always-on brain on a server) makes each workspace in its OWN session
  daemon instead (`DaemonWorkspaces`: `create-workspace` by key,
  `create-terminal` in the subagent's directory, `new-conversation-tab` with
  `agent_session {host: install:<id>, host_name, session, harness}`). The
  subagent runs on that machine, so its workspace belongs to that machine's
  session (data-model.md 1.2); an app shows it while connected to that
  session, and an app on another machine shows the chat tab as running on
  that host until it can attach to that host's acpmux.
- The spawn answer says, per subagent, the workspace it got and where it
  lives (`workspace "a1 · task" in the cmux app on this Mac`), or `no cmux
  workspace (<why>)`: no app socket, workspaces turned off, or the open
  failed. The Chief is told to repeat only that. Before 2026-10-06 the answer
  always said "each in its own cmux workspace", and a headless brain without
  an app socket told the user about workspaces that did not exist.
- Each subagent's report (its last reply) reaches the chat as its own `user`
  message, `[a<N>] report`, when it finishes a turn; the Chief never waits for
  the other subagents of its spawn. It is queued like a human message: it
  starts a turn when the Chief is idle, and on acpmux it stops a working turn
  once no tool runs (the next fresh turn takes it; the native engine delivers
  it at the next tool boundary). Reports queued while the Chief is busy go
  into one turn. A run the user stopped (stop in its pane, `session/cancel`)
  reports `[a<N>] (stopped by the user) ...` quietly: the next turn logs it,
  and it starts no turn. A subagent that runs again later (a `tell`, the user
  writing in its chat) reports again when it finishes.

- At most 16 subagents work at once (`subagents::MAX_LIVE`; one spawn takes
  at most 8 tasks). A spawn over the cap answers `a<N>: queued`; a queued
  subagent starts, with the view of that moment and its task, when another
  finishes. The queue lives in the host's memory: a host that restarts
  reports a still-queued subagent as not started.
- A turn whose subagents are at work gets `Subagents at work now: a1, a3.`
  after the view, before its new messages (never logged).
- `chief.stop` stops the running turn and every subagent at work
  (`session/cancel` on each; their reports come quiet) and drops the queued
  ones; it answers `{"stopped": true, "subagents": [...]}`.
- A subagent prompt the harness fails ends that run with `[a<N>] (failed:
  <error>)`, never a subagent that waits forever.

Deviation: `tell` reaches a running subagent after its current turn (acpmux
queues the prompt; claude-sr has no steering), not between its tool calls.
No cache marker is added to a subagent's first message: one spawn's subagents
start together, so none could read another's entry.

## Engine: harness, model and effort per turn

`$MUX_HOME/optchat/engine.json` (0600) holds `harness`, `model`, `effort`,
`compactor_harness` and `compactor_model`; a missing field is the env default.
The host reads the turn fields at EACH turn start, so a change applies from
the next turn and a running turn finishes on its engine. A turn on a Claude
harness gets the cached layout and the `optchat-chief-<home id>` preset; on
codex, AGENTS.md (always written) and `optchat-chief-codex-<home id>`; both
presets are installed at start. A harness acpmux does not know keeps the
default. Each change is a `note` in the memory ("engine changed to
harness=... model=... effort=... (was ...)") and an `engine` trace event;
`turn.start`/`turn.end` record the engine that answered. The compactor fields
apply at the next host start. `optchat-chief engine show|set` (and `chief
engine ...` inside a turn) read and write the file; the app's Home shows an
engine bar over the Chief conversation (harness, model and effort pickers,
the last turn's engine, latency, tool calls, cache hit rate and cost) that
writes the same file.

## Monitoring: trace and stats

Every turn (`turn.start`, `turn.end`), every model request in a turn
(`request`: Claude Code's per-message usage; codex-acp's last request), every
tool call (`tool`: name, argument bytes, result bytes, ok/error, ms from
acpmux's event times), every compactor node (`node`: ms, prompts, usage, cost,
ok, context hash and piece hashes), every subagent step (`spawn`,
`subagent.start|workspace|answer|input|resume|done`, `tell`, `spawn.report`)
goes to `$MUX_HOME/optchat/traces/YYYY-MM-DD.jsonl` (append only, 0600).
Texts are `{bytes, hash, prefix}` (FNV-1a 64, first 40 characters); tool
arguments are sizes only. `OPTCHAT_TRACE_FULL=1` adds whole texts and tool
arguments (debugging only). `turn.start` carries the view's bytes and lines,
`{bytes, hash}` of each cached piece, the system prompt's hash, and
`unchanged_prefix_bytes` (leading bytes equal to the previous turn's view in
this host), so cache stability is measurable.

```
optchat-chief trace [--since 1h] [--turn ID] [--json] [--mux-home DIR | --dir DIR]
optchat-chief stats [--since 24h] [--json] [--mux-home DIR | --dir DIR]
```

`trace` prints one line per event; `--turn` takes a turn's first message id or
its key and adds the nodes and subagent events inside it. `stats` prints, per
turn, latency, requests, cache hit rate (cache_read / (cache_read +
cache_write + uncached input)), the first request's hit rate (what earlier
turns' cache gave), the unchanged view fraction, cost and tool calls by name
with failures; then compactor nodes and subagents the same way. Both only read.

For the bundled host in a tagged cmux-next DEV app, `MUX_HOME` is
`~/.cmux/mux/tags/<tag>` (`CMUX_NEXT_MUX_HOME` overrides; untagged:
`~/.cmux/mux`), and the binary is inside the app:

```bash
"$HOME/Library/Developer/Xcode/DerivedData/cmux-<tag>/Build/Products/Debug/cmux DEV <tag>.app/Contents/Resources/bin/optchat-chief" \
  stats --mux-home ~/.cmux/mux/tags/<tag>
```

## Run it with a tagged cmux-next build

1. Build the macOS binary on a fleet Mac (cargo never runs on the laptop):

   ```bash
   nx-remote --host cmux-mini-6 --xcode 26.6 --worktree "$PWD" --cwd Native/OptChat/optchat-chief \
     --fetch Native/OptChat/optchat-chief/target/release/optchat-chief \
     -- bash -c "umask 022; OPTCHAT_BUILD_COMMIT=$(git rev-parse --short HEAD) cargo build --release"
   ```

   Copy the fetched file to `Native/OptChat/optchat-chief/dist/optchat-chief` (gitignored).
   Build with `OPTCHAT_BUILD_COMMIT=$(git rev-parse --short HEAD)` in the
   command's environment: the host's first log line names the build, so a
   dogfood run shows which code it runs. Rebuild before every dogfood run.

2. Start the tagged app with `CMUX_NEXT_MUX_HOST` naming that file, in the
   app's own environment (launch its executable from a shell with the
   variable set, or `launchctl setenv CMUX_NEXT_MUX_HOST /abs/path/optchat-chief`
   before `open`). The app starts the host when Home first opens, as
   `optchat-chief host --daemon-socket <daemon socket> --mux-home ~/.cmux/mux/tags/<tag>`,
   with `MUX_AGENT_TOKEN_FILE`, `CMUX_SOCKET_PATH`, `ACPMUX_*`, `MUX_HARNESS`
   and `CMUX_MCP_COMMAND` set. Its stderr goes to `$MUX_HOME/host.log`.

3. Open Home and write in the Chief conversation. The reply shows as the
   `mux` participant (the conversation is the same one mux/host creates).

Only one brain host runs per `MUX_HOME`: this host takes the same kernel lock
as `mux/host` and the P1 Rust Chief (`$MUX_HOME/state/host.lock`), so a second
launch exits 0. Stop a running `mux/host` for that home first.

## Commands

```
optchat-chief host --daemon-socket PATH [--mux-home DIR]   the brain host (one per MUX_HOME)
optchat-chief mcp [--socket PATH | --mux-home DIR] [--role subagent]  stdio MCP server: zoom, date, spawn, tell
optchat-chief spawn "task" ["task" ...] | tell ID "message"  section 9's tools as commands
optchat-chief trace [--since 1h] [--turn ID] [--json]        the monitoring trace, one line per event
optchat-chief stats [--since 24h] [--json]                   latency, tools, cache hit rates, cost
optchat-chief agents spawn --name N --cwd DIR [--harness H] [--policy P] "task"
optchat-chief agents list | prompt NAME "text" | allow NAME [OPTION_ID] | deny NAME
optchat-chief browse [--mux-home DIR] [--out FILE]          the whole memory as one HTML page
optchat-chief import [--mux-home DIR] FILE                  JSON lines {"text", "kind"?, "date"?}, default note, date RFC 3339 (host stopped)
optchat-chief import-claude-code dry-run|write [--projects DIR] [--mux-home DIR] [--append-after-live]
                                                           Claude Code transcripts as messages (host stopped)
optchat-chief memory export --text DIR [--mux-home DIR]    the memory as JSONL day files (read-only; host may run)
optchat-chief memory import [--mux-home DIR] DIR           an old JSONL home or an export into an empty memory (host stopped)
optchat-chief memory search [--mux-home DIR] [--limit N] WORDS  messages and summaries holding every word (FTS5)
optchat-chief memory stats [--mux-home DIR]                counts, schema, migration record, backup status
```

Inside a turn the Chief runs `chief agents ...` (a launcher in
`$MUX_HOME/optchat/bin`, first on the turn's PATH). A child's final reply of
each turn comes back as one message `[<name>] <report>`, which starts a new
turn when the Chief is idle.

### Importing Claude Code sessions

`import-claude-code` reads Claude Code transcripts (`--projects`, default
`$CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects`) and turns each session
into a `note` (session id and working directory), then per turn the user's
message (`user`), one `tool` line with the turn's tool names, counts and the
files they named, and the final reply (`talk`), each with its transcript
date (section 10: "the user's messages and the agent's final replies,
without repeated pastes and tool noise"). Thinking, intermediate replies,
tool inputs and outputs (which can hold secrets), meta lines, slash
commands, interruptions and subagent lines are dropped, as are lines a
resumed session copied (same uuid) and a user message of 500 or more
characters seen before. `dry-run` prints the counts and the date range and
writes nothing; `write` appends the items through the chat (`OptChat`'s
append, the store seam), so it needs the host stopped, and the items get
their ids from the end of the log. Sessions go in order of their first line.
Old history must not land after live messages: on a memory that already
holds messages, `write` refuses and writes nothing unless
`--append-after-live` accepts that the history appears after the current
messages, and `dry-run` warns about it.

## Environment

| variable | default | meaning |
| --- | --- | --- |
| `CMUX_DAEMON_SOCKET` | (`--daemon-socket`) | the session daemon (local-conversations-v1) |
| `MUX_HOME` | `~/.cmux/mux` (`--mux-home`) | where everything lives |
| `MUX_AGENT_TOKEN_FILE` | required (exit 2 without) | the app's agent_mux token |
| `OPTCHAT_CHIEF_ENGINE` | `acpmux` | `acpmux` or `native` (Messages API loop in the host) |
| `OPTCHAT_CHIEF_MODEL` | `claude-opus-5-5` (native), harness default (acpmux) | the turn model |
| `OPTCHAT_CHIEF_EFFORT` | `medium` (Taelin runs Opus 5.5 at medium); acpmux: only on a Claude or codex harness | the turn effort: native `output_config.effort`, acpmux `effort` of each turn session |
| `OPTCHAT_CHIEF_SERVER_FALLBACK` | off | native: `1` sends `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) |
| `OPTCHAT_CHIEF_HARNESS` | `MUX_HARNESS`, else `claude-cr` when acpmux has a configured CodeRouter route, else `claude` | acpmux: the harness of each turn session, and of the compactor unless `OPTCHAT_COMPACTOR_HARNESS` names another |
| `MUX_HARNESS` | `claude` (acpmux resolves it through `defaults.claude.prefer`) | acpmux: the children's default harness, and the turn harness when `OPTCHAT_CHIEF_HARNESS` is unset |
| `MUX_POLICY` | `approve-all` | acpmux: permission policy of each turn session |
| `ACPMUX_SOCKET`, `ACPMUX_HOME` | `~/.acpmux/acpmux.sock` | the acpmux daemon |
| `ACPMUX_BIN` | none | started as `$ACPMUX_BIN daemon run` when the socket does not answer |
| `CMUX_SOCKET_PATH` | none | the app's control socket, passed to the turn's tools |
| `CMUX_MCP_COMMAND` | none | cmux binary whose `mcp serve` is added as MCP server `cmux` |
| `OPTCHAT_ANTHROPIC_BASE_URL` | `http://cmux-lawrences-mac-mini:31415` | the Messages API of the native engine, and of the compactor's `api` route (team subrouter) |
| `OPTCHAT_ANTHROPIC_API_KEY` | none | `x-api-key`; else `ANTHROPIC_API_KEY` for any base URL but the subrouter; else `subrouter` |
| `OPTCHAT_COMPACTOR` | `acpmux` | how summaries are built; `api` only when set (see Compactor routes) |
| `OPTCHAT_COMPACTOR_HARNESS` | the Chief's harness | acpmux route: the harness of the compactor sessions |
| `OPTCHAT_COMPACTOR_MODEL` | `claude-sonnet-5-5` on a Claude harness, else the harness's default | acpmux route: their model (the refusal fallback `claude-sonnet-5` exists on a Claude harness only) |
| `OPTCHAT_COMPACTOR_EFFORT` | `medium` on a Claude or codex harness, else the harness's default | acpmux route: acpmux `effort` of the compactor sessions (section 4.2 runs the compactor at medium) |
| `OPTCHAT_CHIEF_ISOLATE` | `1` | `0` runs turns with the user's own Claude Code configuration; it never changes the compactor's isolation |
| `OPTCHAT_SUBAGENT_HARNESS` | the Chief's harness | section 9: the subagents' harness |
| `OPTCHAT_SUBAGENT_MODEL` | harness default | the subagents' model |
| `OPTCHAT_SUBAGENT_WORKSPACES` | on | `0`: no cmux workspace per subagent |
| `OPTCHAT_CACHE_TTL` | the Chief setting `cache.ttl`, else `1h` on the Claude Code path and `5m` on the native engine | `5m` or `1h`: the TTL of every cache mark of a turn (see Cache marks and TTL) |
| `OPTCHAT_TRACE_FULL` | off | `1`: whole texts and tool arguments in the trace (debugging only) |
| `OPTCHAT_CHIEF_TURN_LIMIT_MIN` | `180` | a turn longer than this is stopped and says so (`0`: no limit) |
| `OPTCHAT_BACKUP_REMOTE` | `optchat/settings.json` `backup.remote`, else on with `gh auth` except tagged dev homes | `on`/`off`: push the text export to `manaflow-ai/chief-memory-<home id>` after each turn (see State and storage) |
| `OPTCHAT_BACKUP_URL` | the per-Chief GitHub repository | push to this git remote instead (no `gh` needed) |

## Files

```
$MUX_HOME/state/host.lock         kernel lock shared with mux/host ("<pid>\n<start ms>\nflock\n")
$MUX_HOME/optchat/memory.sqlite3  the OptChat memory (log, tree, host state, FTS5 indexes), WAL; see State and storage
$MUX_HOME/optchat/chat/           the chat's single-writer lock and the memory's text export: main/YYYY-MM-DD.jsonl,
                                  tree/YYYY-MM-DD.jsonl (.export.json: the export's watermark); a git repository,
                                  committed after every turn (section 10) and pushed to the backup repository
$MUX_HOME/optchat/memory-jsonl-backup-<stamp>/  the old JSONL files of a migrated home, copied before the import
$MUX_HOME/optchat/backup.json     the last backup outcome (ok, held with its text, retrying, off)
$MUX_HOME/optchat/backup-allow.txt  message ids or summary names whose possible secret the user allowed
$MUX_HOME/optchat/settings.json   per-Chief settings: {"backup": {"remote": true|false}}
$MUX_HOME/optchat/AGENTS.md       the user's own instructions, the end of the system prompt (read at host start)
$MUX_HOME/optchat/memory.html     `optchat-chief browse` output
$MUX_HOME/optchat/host.json.imported  the old host state, moved into memory.sqlite3 at the first start
$MUX_HOME/optchat/tools.sock      the live memory for `optchat-chief mcp`
$MUX_HOME/optchat/session/        every turn's cwd: CLAUDE.md (Claude harness, old layout only) or AGENTS.md
                                  (any other harness), .mcp.json, .claude/settings*.json
$MUX_HOME/optchat/bin/chief       launcher for `chief agents ...`
$MUX_HOME/optchat/claude/         the turn sessions' CLAUDE_CONFIG_DIR (settings.json: no auto-memory, no hooks,
                                  transcripts kept 2 days)
$MUX_HOME/optchat/compactor-claude/  the compactor sessions' own CLAUDE_CONFIG_DIR (0700; same settings as below;
                                  unused on claude-sr, which resets CLAUDE_CONFIG_DIR)
$MUX_HOME/optchat/compactor-codex/slot-<k>/  a codex compactor slot's own CODEX_HOME (0700): only config.toml
                                  (the user's routing and model keys, plus no AGENTS.md, skills, apps,
                                  plugins, memories, hooks or history); emptied but for it around every node
$TMPDIR/optchat-compact-<home id>/slot-<k>/  the compactor sessions' working directories (0700), one per slot
                                  on a Claude harness (`shared/` for any other): .claude/settings.json (every
                                  tool denied, all hooks off, no auto-memory, no bundled skills, transcripts
                                  kept 1 day)
<acpmux state>/presets/<preset>/system.md  acpmux's own copy of a preset's systemPrompt (0400 in a 0700
                                  directory; acpmux checks its sha256 at every session start): the turn
                                  preset holds the system text and the view up to 50k, each compactor slot
                                  preset its node's (emptied when the node ends)
```

`$MUX_HOME/optchat/` is mode 0700 and memory.sqlite3 (with its -wal and
-shm) and the export's day files are 0600: the memory keeps everything the
user pasted.

The system prompt (and the acpmux session's `CLAUDE.md`) is the spec's MASTER
and VIEW_DOC (agent renamed "Chief"), a short cmux section, then
`$MUX_HOME/optchat/AGENTS.md` when it exists. The files
this host writes (CLAUDE.md, the MCP tool list, the settings) are
byte-identical across turns. The request the model gets is not fully ours:

- Turn sessions start through an acpmux preset (`optchat-chief-<home id>`,
  saved in acpmux's config) whose env sets `CLAUDE_CONFIG_DIR` to
  `optchat/claude` and turns auto-memory off, so the user's
  `~/.claude/CLAUDE.md`, settings, hooks and project memory never reach a
  turn and MASTER's "instructions at the end of this prompt" holds, except
  on claude-sr, which resets `CLAUDE_CONFIG_DIR` (see Compactor routes). When
  acpmux refuses the preset, turns still start (with the harness's own
  configuration) and host.log says so; compactor sessions never do.
  Claude Code keeps each turn's transcript (the whole view) for 2 days
  (`cleanupPeriodDays`, minimum 1, set in both the isolated configuration
  and the session directory's project settings); on claude-sr the
  transcripts are under `~/.claude/projects/`, and whether a project-level
  `cleanupPeriodDays` governs that sweep is not checked.
- Claude Code's own system prompt still comes first, with its date and
  environment lines, so the cached prefix changes at least once a day.
  Machine-wide managed settings still apply.

## State and storage

Decision 2026-10-06: the memory is ONE SQLite file per Chief home,
`$MUX_HOME/optchat/memory.sqlite3`, and the JSONL day files the memory was
stored in before are a plain-text export rebuilt from it, for reading, `rg`
and backup.

**Owner.** The brain host is the only writer. It keeps its single-writer
locks (`$MUX_HOME/state/host.lock` and the chat's `lock` socket) and writes
through one connection, which the chat's mutex serializes (the brain thread,
turn workers and compactor workers take turns on it; no second writer
connection exists). Readers open read-only connections and work while the
host runs: the persister's export, `optchat-chief memory export|search|stats`,
and the app's debug view when it reads the file.

**File.** WAL, `synchronous=FULL`, `fullfsync=ON` and
`checkpoint_fullfsync=ON` (F_FULLFSYNC on Apple platforms, where a plain
fsync stops at the drive's cache), so a commit is on the disk when it
returns, as each fsynced line was; `busy_timeout` 10 s;
`journal_size_limit` 64 MiB; prepared statements cached per connection.
Mode 0600 (SQLite gives -wal and -shm the same mode).

**Tables** (`optchat-host/src/db/schema.rs`, `schema_version` plus one
migration per version, each in its own transaction):

| table | what |
| --- | --- |
| `messages(id INTEGER PRIMARY KEY, kind, date, day, text, conv_msg UNIQUE, attachments)` | the log; `id` dense 0..T; `day` is the export's day file; `conv_msg` is `<conversation>#<seq>` of a human message, so the same message is never logged twice; `attachments` a JSON array (unused until images land) |
| `nodes(level, idx, bytes, day, text, PRIMARY KEY(level, idx))` | the tree; the rowid is the storage order the export keeps; `nodes_size(level, idx, bytes)` covers what the start reads |
| `state(key PRIMARY KEY, value)` | the host state, one JSON value per `HostState` field (`host/<field>`: read cursor, pending turn with the acpmux session id, outbox, orphans, children, ...), each turn session's fold position (`fold/<session id>`: the last event seq in the log), the migration record (`memory/migration`) |
| `messages_fts`, `nodes_fts` | FTS5 over both texts, external content (the text is stored once), kept by insert triggers |

**Atomicity.** Each of these is ONE transaction, which closes the crash
windows the audits found:

- A turn's messages, their bookkeeping (the read cursor, each child's report
  marked) and the pending turn with its reply key (`Brain::log_items`, also
  for messages delivered between tool calls). Before, the pending turn was
  saved, the messages appended one fsync each, then the key saved; a restart
  had to infer which reached the log from its length.
- A fetch of a turn's acpmux events: the folded talk, tool and echo entries
  and the session's new fold position (`turn::append_folded`). Before, the
  entries were appended and the position reached host.json later through the
  brain, so a crash between them folded the same steps again at the next
  start (stale `after`). The session's position is written when the turn
  creates it, before its prompt starts, so a host that never heard the
  session's id still finds and folds it.
- A compactor node (or a batch of free nodes) and its completion: the row
  commits before the core counts the node built.

Restart recovery needs no harness session files: the pending turn and the
fold positions say where each turn session stands, and the session's acpmux
events after the stored seq are folded (any ACP harness). A crash before a
commit leaves nothing of that transaction, so its messages are caught up
again from the conversation and answered normally; one after it finds them
logged and the pending turn on record (the user hears the turn stopped).

**Traces** stay JSONL (`optchat/traces/`, the trace branch's format), not in
the memory file: they are a log of what happened, written often, never
read back by the host, and need no fsync.

**Export.** `optchat_host::db::export_text` writes `main/<day>.jsonl`
(`{i, kind, text, size, date}`) and `tree/<day>.jsonl` (`{l, i, text,
size}`) from one snapshot: each day file holds that day's messages in id
order and its nodes in storage order, so the export of a migrated home is
byte-identical to its old files (tested on the fixture). A day file whose
bytes did not change is not rewritten, so git sees no change. The persister
keeps `chat/` in step after every turn (`Exporter`: a full export the first
time, then only the rows stored since, by the watermark in `.export.json`),
commits it, and pushes it. `memory import` takes either layout (the old
store's files or an export) into an empty memory.

**Backup** (decision 2026-10-06). After the commit, the export's history is
pushed to a private `manaflow-ai/chief-memory-<home id>` repository, which
`gh repo create --private` makes on the first push; never forced, so a
remote with other history fails the push and stays as it is. Before each
push the lines added since the last pushed commit are scanned (gitleaks when
it is on PATH, else built-in shapes: GitHub, Anthropic, OpenAI, AWS, Slack,
Stripe, Google and npm tokens, private keys). A hit holds the backup:
nothing is pushed, `optchat/backup.json` says `(backup held: possible secret
in message N)`, a `backup_held` trace event is written, host.log says how to
release it (the message id or summary name on a line of
`optchat/backup-allow.txt`). A failed push is retried by the persister
thread after 30 s, doubling to 30 min; a turn never waits on it. On by
default when `gh auth status` succeeds, except for tagged dev homes
(`.../tags/<tag>`), which would each make their own repository; set
`OPTCHAT_BACKUP_REMOTE` or `settings.json` to choose.

**Migration.** On the first start with an old home (day files in `chat/`,
an empty database), the host copies them into
`memory-jsonl-backup-<stamp>/`, imports them in one transaction (torn,
invalid, duplicate and out-of-range lines reported and skipped, ids checked
to be 0..T), renders every stored row again and compares count and hash
with what it read, and records `memory/migration` in the same transaction.
A crash before the commit leaves the database empty and the next start does
it again; a recorded migration or a non-empty database never imports again.
`host.json` moves into `state` the same way (renamed `host.json.imported`).
The old files stay in `chat/` as the start of the export, so its git
history goes on.

**Resource use.** No index lives in memory: a message or node is read by
primary key. The start reads the largest message id and node rowid, the
saved checkpoint (`memory/checkpoint`: T, the lowest unbuilt index per
level, the view's parts), the frontier nodes above each level's low by key
range, and the view's sizes by key; then it folds the messages logged after
the checkpoint (fewer than 256 unless the host crashed after a long run).
optchat-core stays sans-I/O: a lazy `Memory` holds only the frontier and the
view's sizes and asks `Store::node_size` for a merged node's size when a
merge needs it (`Memory::resume`, `append_in`, `complete_in`). The fold from
message 0 (section 5.2, "At load") runs only when there is no usable
checkpoint: the first start after the migration or an upgrade, or a
checkpoint more than 4,096 messages behind.

Start, after the checkpoint exists (`optchat-host/tests/start.rs`, ignored
1M test; `optchat-chief memory check` on the Mac):

| messages | Testbox open | Testbox RSS | Mac open | Mac max RSS |
| --- | --- | --- | --- | --- |
| 10k | 8 ms | 6.6 MB | 1.9 ms | 8.8 MB |
| 100k | 10 ms | 6.9 MB | 2.0 ms | 8.9 MB |
| 1M | 10 ms (1 ms in the 1M test) | 7.0 MB | 2.0 ms | 9.0 MB |

The first start of a migrated home pays the import and one fold: on the Mac
0.34 s, 7.8 s and 70 s (822 MB peak) at 10k, 100k and 1M, once.

**Writer contention.** `tests/bench.rs contention`: four threads append
while a reader renders the view and zooms. Reader p50/p99 were 2.6/3.4 ms
during the writes and 3.6/3.7 ms with no writer, appends 0.14/0.73 ms; no
contention, so the writer stays one connection behind the chat's mutex. On
a Mac a reader can wait one commit (about 8.5 ms with F_FULLFSYNC); a
read-only connection for the tools would remove that, a writer thread would
not (reads need the same memory state).

**The migration's copy** of the old files is imported again into a scratch
database a week after the migration (on its own thread, the start does not
wait); when its counts and hash are the ones recorded, it is deleted and
the record gets `backup_deleted` (host.log says so); otherwise it is kept and
host.log says why.

The numbers before the checkpoint (2026-10-06, first SQLite commit):

Measured with `optchat-host/tests/bench.rs` on a Blacksmith Testbox (Linux
6.6, AMD EPYC, 32 vCPU, page cache warm; its fsync costs 0.2 ms, much less
than F_FULLFSYNC on a Mac), synthetic homes with every node built (about 2T
nodes), each number from a fresh process, append = 200 short messages one by
one:

| messages | store | open | RSS after open | peak RSS | append p50 / p99 | disk |
| --- | --- | --- | --- | --- | --- | --- |
| 10k | JSONL | 75 ms | 7.5 MB | 10.8 MB | 0.21 / 0.85 ms | 6.4 MB |
| 10k | SQLite | 71 ms | 7.6 MB | 8.7 MB | 0.22 / 1.79 ms | 13.2 MB db |
| 100k | JSONL | 852 ms | 22.3 MB | 86.4 MB | 0.22 / 0.81 ms | 63 MB |
| 100k | SQLite | 809 ms | 14.7 MB | 17.9 MB | 0.24 / 1.85 ms | 94 MB db |
| 1M | JSONL | 8.97 s | 215 MB | 849 MB | 0.21 / 0.82 ms | 637 MB |
| 1M | SQLite | 8.00 s | 111 MB | 156 MB | 0.18 / 1.75 ms | 898 MB db |

The migration (first open) took 0.35 s, 4.5 s and 48 s at 10k, 100k and 1M.

On a Mac (cmux-lawrence-2, Apple M5 Pro, macOS 27.0.1, F_FULLFSYNC), 500
short notes through `optchat-chief import` (each one message commit plus its
free node commit): 8.5 ms per append on SQLite (bd583f5eaa8), 11.5 ms on
the line store (0af8c9ba1b5, two fsynced lines).
The database is 1.4x the JSONL it came from (FTS and indexes), and a
migrated home also keeps the export (1x) and the backup copy (1x).

## Harnesses and cache layout

**Claude runs only on acpmux's own adapter** (`src/harness_gate.rs`,
2026-10-05). Before each turn, compactor node and subagent session the
Chief reads `_acpmux/harnesses` and admits a Claude harness only when
acpmux reports it as kind `claude-stdio`. `claude-sr` and `claude` are
routes: the Chief asks for the `claude-stdio` profile whose command is
`sr claude proxy` (or `subrouter claude proxy`), or `claude`, whatever
that profile is named. Any other Claude-family profile must also be kind
`claude-stdio`. `claude-sr` also accepts acpmux's routed copy (a failing `sr claude
proxy` replaced by a `claude-stdio` profile that runs `claude` with no
arguments) only when its `ANTHROPIC_BASE_URL` is the team subrouter on
cmux-lawrence (`harness_gate::TEAM_SUBROUTER_URLS`); a real `sr claude
proxy` profile wins over it. A refused turn starts no session and posts `(turn refused:
...)` in the chat. A session that acpmux resolved or moved onto another
profile is checked again by its own harness, at the start and at the end
of the turn. Every refusal is a `harness.refused` trace event (role,
harness, reason), and each `turn.end` records `harness_profile`,
`harness_kind` and `harness_argv0`. The gate exists because a tagged
acpmux home has no config of its own: it imports `~/.acpx` entries as
kind `acp`, and when `sr claude proxy --version` fails it replaces
claude-sr with a copy of `claude`. On Lawrence's laptop both names ran
the external claude-acp adapter on 2026-10-05.

The Chief runs purely on local ACP: turns and summaries are acpmux
sessions, and the harness is one setting, `OPTCHAT_CHIEF_HARNESS` (the
Chief record in the app can carry the same value later). The default,
claude-sr, is acpmux's own Claude Code adapter (`cmux-tui/crates/acpmux/src/claude_stdio`,
first-party since 2026-09-17; it drives `claude -p` over stream-json and
`sr claude proxy` gives it the subrouter's account pool). The compactor
follows the Chief's harness unless `OPTCHAT_COMPACTOR_HARNESS` says
otherwise. Changing the value needs no code change; each family gets the
layout its cache needs. The family is what acpmux says the harness is
(`_acpmux/harnesses`: a declared `family`, else the harness kind and
command, so `claude-stdio` or a `claude` command is Claude and a
`codex-acp` command is codex), read once at host start; a harness's name
decides nothing. The host stops with a host.log line when acpmux cannot
answer (except the native engine with the API compactor, which needs no
acpmux):

| harness | turn layout | node layout | cache mechanism | measured (2026-10-04, cmux-lawrence-2) |
| --- | --- | --- | --- | --- |
| Claude family (claude, claude-sr) | turn preset `systemPrompt` = the constant system text; prompt = the view in 4-line blocks with ONE `cache_control` mark (`optchat_core::mark_piece`, 1 hour by default), then the new messages; no CLAUDE.md | slot preset `systemPrompt` = the same system text; the context in 4-line blocks with one 5-minute mark; then the step | Claude Code's own breakpoints (its system blocks, the request end) plus ours, all of one TTL | 2026-10-08, capture proxy: a warm turn reads everything up to our mark; see Cache marks and TTL |
| codex family | view pieces first, new messages last, no marker; instructions in the session directory's AGENTS.md; memory tools as `chief zoom` / `chief date` | system text, context pieces, step; all nodes in one shared cwd | OpenAI automatic prefix caching (1024-token blocks), routed by `prompt_cache_key`: `optchat-<home id>-turn` for turns, `optchat-<home id>-compact` for nodes (needs the cmux codex fork) | upstream key (thread id): 2nd turn read 12,032 of 56,632 (21%), 2nd node 12,032 of 48,653 (25%). Fork with the Chief's keys (2026-10-04, see Codex): 2nd turn read 56,064 of ~56,630 (99%) in 6 of 8 runs; 2nd node 44,800 of 45,662 (98%) in 3 of 5 |
| any other acpmux harness | as codex | as codex | whatever the harness does with a byte-stable prefix | not measured |

Every turn logs `turn <key> cache: first request read .. written ..
uncached ..; turn total|last request ...` to host.log (Claude Code reports
the turn's total and its first request; codex-acp reports the turn's last
request), and every node `compactor node <id> (<harness>, <model>): ..,
uncached .. cache write .. cache read .. output ..`. The live check is
`OPTCHAT_CHIEF_HARNESS=<h> cargo test --release --test live
two_turns_and_two_nodes_through_local_acp -- --ignored --nocapture` against
a private acpmux daemon built from `feat-cache-control-preset-args`
(measured at e2715f27657): two consecutive turns over a 120 KB view (marks
49,983 / 79,975 / 99,919) and two consecutive nodes over a 127 KB context,
the turns on the harness's default model, the Claude nodes on
`claude-sonnet-5-5`.

**Claude.** acpmux takes a preset's system prompt as text
(`systemPrompt`), writes it into its own preset directory, records its
sha256 and checks it at every session start, and passes
`--system-prompt-file` itself; preset `args` are an allowlist that can only
take capabilities away (`--tools ""`, `--strict-mcp-config`,
`--no-session-persistence`). A turn sets the turn preset's prompt just
before its session starts (turns run one at a time); each compactor slot
has its own preset (`optchat-compact-<home id>-slot-<k>`), so concurrent
nodes never race on one prompt. The prompt changes only when the view
before the 50k mark changes (a merge of old lines), so consecutive turns
send byte-identical system prompts. A 4-breakpoint refusal (`A maximum of 4
blocks with cache_control`) reruns the turn once without the marker, and
later turns skip it. An acpmux without `systemPrompt` keeps the old layout
(no marker, CLAUDE.md, host.log says so).

**Cache marks and TTL.** Measured on the requests Claude Code 2.1.287
sends (a capture proxy on a scratch route, 2026-10-08): Claude Code sends its
tools, a marked system block of its own, our system prompt (marked), our
user blocks, then a mid-conversation system message (cwd, model, date,
deferred tools, agent types, skills) with its own mark at the request end.
That message comes after the view, so it is written again each turn (about
1,800 tokens through `sr`, whose shared configuration lists the user's
skills, with Task and Agent denied as turns do) but never moves the prefix. Two consecutive turns send
the same bytes up to the earlier turn's mark, and the later turn reads
through it. Two rules keep that true:

- Our mark sits on the last whole 4-line block of the view, but never more
  than 16 blocks (`MARK_REACH`) past the last turn's mark: the API looks back
  only 20 blocks from a mark, so a turn that added more than 80 view lines (a
  long tool run) would otherwise write the whole view again. Such a turn
  writes the new lines once and the next turns catch up.
- Every mark of one request has one TTL, since the API refuses a 1h mark
  after a 5m one. On the Claude Code path our mark is 1 hour by default
  (a human reply 5 to 60 minutes later still reads the view), and each turn
  writes `promptCacheTtl` into the session directory's Claude Code project
  settings so Claude Code's own marks match. `OPTCHAT_CACHE_TTL` (`5m` or
  `1h`) at host start (Claude Code's own `FORCE_PROMPT_CACHING_5M` or
  `CLAUDE_CODE_PROMPT_CACHE_TTL` in the host env win over it, since every
  turn's harness inherits them), else the Chief setting `cache.ttl`
  (`optchat-chief settings set cache.ttl 5m`, from the next turn), picks
  another TTL. The native engine (a direct API call) defaults to 5 minutes
  and reads the same two at host start. A route that refuses the 1-hour TTL
  reruns the turn at 5 minutes, and later turns stay at 5 minutes until the
  host restarts or `cache.ttl` is set again (`turn.ttl_refused` trace event).
  Compactor sessions pin `promptCacheTtl` to 5m, the TTL of their own mark;
  1h and 5m entries are one cache (measured), so a node still reads what a
  turn wrote.

`turn.start` records the marked piece and the TTL (`layout.mark`,
`layout.ttl`) and the inspector lays the prompt out from them.
`optchat-core/tests/cache_replay_long.rs` replays 10,000 messages (batch
merges, 9 tree levels, human gaps, long tool runs, resumes) against a model
of the API's cache: warm turns read at least 95% of their prefix in every
50-turn window with 1-hour marks.

**Codex.** Its request is `instructions`, the tool list, the permission and
environment messages (cwd, shell, date), AGENTS.md, then our blocks, so
the prefix is byte-stable up to the first changed view line except once a
day (the date). Upstream codex sets `prompt_cache_key` to the thread id
(`codex-rs/core/src/client.rs`), and acpmux starts a fresh thread per
turn and per node, so every request had a new key: the measured 12,032
cached tokens were codex's own instructions and tools, and the view was
never read back. The cmux codex fork (manaflow-ai/codex
`feat/prompt-cache-key-override`) sends `CODEX_PROMPT_CACHE_KEY` (or
`prompt_cache_key` in config.toml) instead; the turn preset sets
`optchat-<home id>-turn` and every compactor slot preset
`optchat-<home id>-compact` through env only (the preset args allowlist
is unchanged). Upstream codex ignores the env, so the layout still works
there, without the reads. Measured on cmux-lawrence-2 (fork build
d73c9c33c6, acpmux e2715f27657, subrouter, `OPTCHAT_LIVE_CODEX_PATH`;
`OPTCHAT_LIVE_NO_CACHE_KEY=1` drops the keys): with keys the 2nd turn read
56,064 tokens in 6 of 8 runs (the misses read 0 and 12,032), and the 2nd
node read 44,800 in 3 of 5 (the misses read 9,984, codex's instructions
only). Without keys, the 2nd turn read 56,064 in 1 of 6 runs (otherwise 0
or 12,032), and the 2nd node never read more than 10,752 in 5 runs. The
remaining misses are most likely the subrouter placing the request on
another account (the cache is per account); that was not proven. The
subrouter keeps a codex installation id on one account: two
`CODEX_HOME`s with their own ids read 0 of a 31.5k-token prefix the other
wrote, and with one shared id they read 30,464. So every compactor slot
sends one stable Chief installation id.

**Codex compactor isolation.** Each compactor slot's preset points
`CODEX_HOME` at the slot's own directory, whose config.toml keeps only the
user's routing and model keys (`model`, `model_provider`,
`model_providers`, `openai_base_url`, `chatgpt_base_url`, `service_tier`,
`model_reasoning_effort`, `model_verbosity`) and turns off project
AGENTS.md, skills (none loaded, none listed), apps, plugins, memories,
hooks, subagents, code mode and history. The slot's auth.json is a
symlink to the user's: codex-acp refuses `session/new` without a sign-in
("Authentication required", checked live), a copy whose token refresh
rotated the refresh token would sign the user out, and codex rewrites
auth.json in place, so a refresh through the link updates the user's own
file. A sign-in kept in the keyring instead of auth.json is not linked. The node's rollout, thread database and logs are
deleted when it ends (and a crash's leftovers before the next node in the
slot). The start-up probe fails when the session lists any `$skill`
command.
acpmux gives codex no MCP servers, so the memory tools are the launcher's
`zoom` and `date` commands (`optchat-chief zoom ID N`, `optchat-chief date
ID`), named by absolute path in AGENTS.md.

**Session tags.** Every turn session and compactor session carries
`cmux.chief=<home id>` and `cmux.chief.role=turn|compactor`, set right
after `session/new` (a session that cannot be tagged is killed), so quit
counts and endAgents can exclude the Chief's own sessions. Children keep
`mux.parent` only.

**One subrouter account per Chief role.** Each turn is a fresh `claude -p`
with a new `X-Claude-Code-Session-Id`, so the subrouter placed turns on any
account and a turn often read nothing of the cache the previous turn wrote
(first-request hit 40% over 8 turns on cmux-lawrence-2, 2026-10-06; 0% in 4
of them). The turn, compactor and subagent presets set
`SUBROUTER_SESSION_KEY=optchat-<home id>-turn|compact|sub`, which `sr claude
proxy` (subrouter v0.1.137, PR 511) sends as `X-Subrouter-Session`; the
server keeps each key on one sticky account (failover still moves it). After
the change, 6 consecutive turns: the first wrote 17,950, each later one read
9,965 (55%) and wrote about 8,000, the part after Claude Code's system
breakpoint (the view below the 50k mark, the new message, Claude Code's own
context). Trade-off: one busy Chief concentrates on one account until failover.

**Grid marker in the turn's view.** The view after its first mark (all of
a view below 50k) goes as one block per 4,096-character grid piece (the last
line end at or before every 4,096 characters from the view's start, so an
unchanged prefix keeps its cuts), and our one marker sits on the piece that
ends at the last cut; the next turn has a block boundary at the same offset,
which the API's lookback from its marker reads. Measured on cmux-lawrence-2
(2026-10-06, six short turns, 8 KB view, subrouter v0.1.137): turns 2-6 read
15,630 and wrote 2,730-2,890 (84-85%), from 9,965 read and about 8,000
written (55%) with the session key alone. The compactor keeps its
50k/80k/100k layout (`cached_layout_at_marks`).

## Compactor routes

The team subrouter serves Claude Code clients: a raw Messages API call for a
Claude model gets `429 rate_limit_error` every time (checked live on
2026-10-04), so a compactor that calls the API there builds no node that
needs a model, and every turn then waits on settle forever. The route is
acpmux unless `OPTCHAT_COMPACTOR=api`:

- `acpmux` (default):
  each node is built in its own acpmux session of `OPTCHAT_COMPACTOR_HARNESS`
  (claude-sr), as `mux/host/src/compactor.ts` does. The session runs with the
  `deny-all` policy and the compactor's own acpmux presets
  (`optchat-compact-<home id>-slot-<k>`, one per slot), which it requires: when acpmux refuses the
  preset, no compactor session starts (nodes fail and are retried, and the
  probe says why), so a node never runs with the user's `~/.claude` hooks,
  MCP servers or auto-memory. The preset sets `CLAUDE_CONFIG_DIR` to
  `optchat/compactor-claude` (not the turn agent's) and turns off
  auto-memory, CLAUDE.md files, bundled skills and Claude Code's own refusal
  fallback. The cwd is a slot directory under the system temporary
  directory, outside any directory with instruction files, whose
  `.claude/settings.json` denies every built-in tool (the interactive ones
  included; a denied tool leaves the model's tool list), disables all hooks
  and auto-memory. The first prompt follows the cached layout (see
  [Compactor cache](#compactor-cache)) when acpmux took the presets' `systemPrompt`,
  else the old layout: the compactor's system text, the context pieces and
  the step; each size-loop retry is the next prompt in the same session;
  the reply text is the line, with a lead-in line ("Here is the line:") dropped. When the node
  is built or fails, the session is killed with purge and Claude Code's
  transcript of it is deleted, and host.log gets one line with the node's
  seconds, prompts and token use (`compactor node <id> (<model>): 9.8 s, 1
  prompt(s), uncached .. cache write .. cache read .. output .., $..`). At
  most COMPACTOR_SESSIONS (16) compactor sessions live at once, main and
  fallback model together; the main compactor keeps up to WARM_SESSIONS (4)
  of them started ahead, so a node prompts a ready Claude Code process (one
  node per session: each node needs a fresh conversation). Nothing pretends to be Claude Code and no API key is involved:
  the harness signs in as it always does.
- `api`: the Messages API at `OPTCHAT_ANTHROPIC_BASE_URL` with
  `OPTCHAT_ANTHROPIC_API_KEY` (or `ANTHROPIC_API_KEY` off the subrouter),
  for an endpoint that takes API calls.

At start the host builds one probe node through the chosen route, with the
main model and then the refusal fallback model, and on the acpmux route
checks that the session's Claude Code offers no tool and no MCP server (its
`system/init`, which acpmux records). When any of that fails (acpmux down,
the harness not signed in, a 429, an unserved fallback model, a tool left
on), host.log gets one `The memory compactor cannot build summaries ...`
line and the Chief conversation gets the same text once, instead of a
silent wait later.
Checked live on 2026-10-04 on cmux-lawrence-2 against a private acpmux
daemon (claude-sr, Claude Code 2.1.287, `claude-sonnet-5-5`), with
`cargo test --release --test live the_acpmux_compactor -- --ignored`:

| call | seconds | uncached | cache write | cache read | output | cost |
| --- | --- | --- | --- | --- | --- | --- |
| probe (empty view) | 1.6 | 2 | 2,442 | 0 | 28 | $0.006 |
| one node, full-size view (127 KB) | 3.7 | 2 | 48,080 | 1,175 | 124 | $0.122 |
| a 120-line message (empty view) | 2.4 | 2 | 5,766 | 1,175 | 86 | $0.016 |

The probe's isolation check passed (no tool, no MCP server), and no
compactor transcript was left in either Claude home. Before the deny list
moved into each slot's project settings, the same probe offered 26 tools
and cost 37,436 cache-write tokens.

**Cost.** In the old layout a node pays for its whole view at the
cache-write price: about 48k tokens and $0.12 at full size, and about 4 s,
of which about 1.5 s is the harness start. Nothing carries the view from
one node to the next (only Claude Code's own 1.2k-token prefix is read
back). Summaries run at roughly 1.2 nodes per message, so a full memory
costs roughly $0.15 per message in compactor calls, $150 a day at 1,000
messages; level-0 nodes run one at a time (rule 3), so a burst of tool
steps can keep the next turn waiting by about 4 s per step. The cached
layout cuts a node whose view is unchanged up to the 100k mark to about
$0.035 (measured below).

## Compactor cache

acpmux with preset `args`, `systemPrompt` and `cache_control` forwarding
(landed on `feat-cmux-next` at 3a6d7b3ec59) lets each node read most of
its view from the cache. Each slot preset (Claude harnesses only) carries
the args `--tools "" --strict-mcp-config --no-session-persistence` and a
`systemPrompt` the node sets before its session starts (acpmux writes the
file into its own preset directory, never the slot directory the agent can
write, and checks its sha256 at the start). A node in the cached layout:

1. The slot preset's system prompt: the compactor's system text, a blank
   line, and the context up to its first cache mark (50k characters). It replaces
   Claude Code's default system prompt, whose cwd and date lines made every
   node (8 slot directories) miss the cache, so the cache now crosses slots.
2. The first prompt: the context from 50k on, one block per piece, with ONE
   `cache_control` marker (`{"type": "ephemeral"}`) on the piece that ends
   at the last mark (100k, else 80k; no marker when only 50k exists, since
   Claude Code's own breakpoint covers the system prompt), then the step.
   Size-loop retries stay in the session, unchanged.

Measured live on 2026-10-04 on cmux-lawrence-2 (claude-sr through the team
subrouter, Claude Code 2.1.287, `claude-sonnet-5-5`, a private acpmux daemon
built from #17283, the blocks built by `cached_prompt`): two consecutive
nodes of a full-size view (127 KB, marks at 49,857, 79,817 and 99,977),
identical up to the 100k mark, the second in another slot directory:

| node | seconds | uncached | cache write | cache read | output | cost |
| --- | --- | --- | --- | --- | --- | --- |
| first (cold) | 3.9 | 2 | 48,079 | 0 | 160 | $0.122 |
| next, same view up to 100k | 4.2 | 2 | 10,771 | 37,671 | 46 | $0.035 |

Both sessions reported no tool and no MCP server, and no transcript was
written. The cache lasts 5 minutes, so it pays only when nodes come close
together (they do in a burst, which is when cost adds up).

Trade-offs and risks:

- **The 80k mark is lost.** Claude Code places 3 of the API's 4 cache
  breakpoints itself, also with a replaced system prompt,
  checked live: three markers of ours got `400 A maximum of 4 blocks with
  cache_control may be provided. Found 6.` One marker is all a node gets, so
  it sits at 100k; a node whose view changed between 80k and 100k reads only
  the system prompt (up to 50k) back, about $0.075 at full size instead of
  $0.035 (cache research, 2026-10-04).
- **A fourth Claude Code breakpoint.** If a later Claude Code places all 4,
  every marked prompt fails with that 400. The compactor then ends the
  session, retries the node once in a fresh session without the marker, and
  logs `compactor node <id>: Claude Code refused the cache_control marker
  (...); retrying without it, and later nodes go without it`; later nodes of
  that host skip the marker (only the system prompt is cached) until it
  restarts.
- **Feature detection.** The host installs the presets with their args and
  a seed `systemPrompt`; an acpmux that does not know a key refuses it
  (`unknown preset key "systemPrompt"`), host.log says `acpmux refused the
  systemPrompt of preset ...; installed without it`, and turns and nodes
  keep the old layout. A non-Claude harness gets neither and the old
  layout.

**claude-sr resets `CLAUDE_CONFIG_DIR`.** `sr claude proxy` points Claude
Code at the user's `~/.claude` whatever the session's env says (checked
live: transcripts land in `~/.claude/projects/`, and deny rules in the
preset's configuration are not applied). So on claude-sr the isolation
presets change little: what isolates a session is its cwd's project
settings (applied, checked live) and the env flags that sr passes through
(not checked one by one). Compactor sessions therefore get their deny list,
`disableAllHooks` and no auto-memory as project settings in each slot
directory, `end` deletes the transcript from `~/.claude/projects/` too, and
the probe's tool and MCP check is the guard. Turn sessions get the same
three switches and the transcript retention in their project settings, but
the user's `~/.claude/CLAUDE.md` and MCP servers can still reach a turn on
claude-sr. The isolated configurations work as described for a harness
that keeps `CLAUDE_CONFIG_DIR`.

The native engine still needs an endpoint that takes API calls; through the
subrouter it gets the same 429 (`--test live two_native_turns` repeats it).

## Remote-origin messages

Taelin gives his Chief tasks from his phone. In cmux a paired device (the
iPhone, another Mac) reaches the Chief conversation through the session
daemon's remote relay as participant `remote_<install>`, and the owner stamps
each message it sends with `origin: {kind: "remote", install}`. The shared
wake rule (`cmux_chief::rules::wakes`, also used by the P1 Rust Chief) still
refuses every such message. The Chief uses `wake::chief_wakes`: the shared
rule for local messages, plus a remote-origin gate, default deny, that
passes a device message only when all of these hold:

1. `origin` is `Remote { install }` and the author is exactly
   `remote_<install>` (the owner stamps the origin from the op's actor, never
   from the request; a local author with a remote origin, a device author
   without one, or a mismatched install is refused);
2. the author is a human participant of this conversation with `person:
   "user_local"`: the daemon's system-only pairing path is the only way to
   create that participant, and it does so only for an install the server
   owner paired with their own account. A device of another person or of no
   person, or a non-human participant, is refused;
3. the message is not retracted and the Chief participates;
4. the shared rule's conversation test with humans counted as persons: one
   person and the Chief, a DM, a mention of the Chief or a reply to one of
   its messages. A device message in a group without a mention is not logged.

A turn that a device message started, or that supersedes such a turn (a
local message that stops a remote-origin turn mid-way), runs with acpmux
policy `ask` instead of `MUX_POLICY` (approve-all): the strictest origin of
the turn wins until it ends.

- Every permission request of that turn session waits. The memory tools
  (`mcp__optchat__zoom`, `mcp__optchat__date`) are allowed at once: they only
  read the OptChat memory. Plain replies need nothing.
- Any other request (a shell command, a file write or edit, a workspace or
  subagent spawn through `cmux` or `chief`, computer use) is posted in the
  Chief chat with the tool and its input: "Approval needed ... Reply allow or
  deny." The next message `allow` or `deny` from a person the gate admits (the
  Mac user or their own paired device) answers the oldest request, with the
  allow-once or reject-once option (never "always"), and is logged; it is not
  a new message and does not interrupt the turn. Any other new message denies
  the pending requests so the turn can stop and the next one answers.
- Every answer goes to the trace (`optchat/traces/YYYY-MM-DD.jsonl`, event
  `approval`: turn, permission, tool, decision, option, approver, install,
  delivered); the approver is the answering participant (`user_local` or
  `remote_<install>`, with the install), or why it was denied.
- Children inherit `ask`, transitively. `chief agents spawn` asks the host
  for its spawn floor: `ask` while an `ask` turn runs or while any child that
  runs with `ask` is live (so whatever such a child spawns asks too; the
  floor errs strict, and a local turn's spawn during that time asks as
  well). The floor wins over `--policy` and `MUX_POLICY`; a host that does
  not answer gives `ask` (fail closed). Such a child is tagged
  `optchat.policy=ask`, its permission requests are asked in the Chief chat
  with its name and answered by `allow`/`deny` like the turn's (the trace
  names the child), and `chief agents allow|deny` refuses to answer them. A
  child name that exists without `ask` is not reused by such a spawn.
  `remote.autoApprove`, set from the Mac, removes the floor; it cannot be
  turned on while an `ask` child is live. The host-served section 9
  `spawn` takes the same floor (`Brain::spawn_policy` at registration): its
  subagents start with `ask` and the tag, and their requests are asked in
  the Chief chat with their id (`a<N>`).
- The native engine cannot ask the chat yet: in such a turn it refuses its
  bash and editor tools and says so to the model.
- Codex harnesses run `chief zoom` and `chief date` as shell commands, so on
  codex those need an approval too.

**Default (Lawrence, 2026-10-06: "i dont want stuff to require my
approval since it is annoying"): `remote.autoApprove` is true.** A turn from
the owner's own paired device then runs with the normal policy
(`MUX_POLICY`, approve-all), and nothing it spawns gets the ask floor. The
gate itself is unchanged: only the owner's own paired installs wake the
Chief; another account, a forged or missing origin, and a group message
without a mention never do. The approvals, the spawn floor and the approval
trace above are what `remote.autoApprove` false turns back on (from the Mac).

`remote.autoApprove` (per Chief, `optchat/settings.json`, default true; the
Chief settings sidebar shows it later; `optchat-chief settings set
remote.autoApprove true|false` today) runs remote-origin turns with
`MUX_POLICY` instead. The host owns the value: it reads the file at start and
changes it only through `Brain::set_setting`, which refuses to turn it on
while remote-origin work runs, settles or waits in the queue, whoever asks (a
command an approved remote turn runs reaches the host the same way). No chat
message changes it. With the host stopped, the CLI edits the file directly
(no turn can run then). Turning it off is always allowed.

Policy analysis (the relay rules of this repository's CLAUDE.md):

- Local command or content execution. The gate adds no relay command, no
  allowlist entry and no parameter: the device still uses only the relay's
  existing conversation commands (`message.send` with text parts), whose gate
  refuses command-bearing params and non-text parts. A device message reaches
  a turn as the user's words. By default that turn runs with the normal
  policy, like a message typed on the Mac; with `remote.autoApprove` false
  it runs with policy `ask`: no local effect happens without an approval the
  user sees in the Chief chat, with the command or input shown. Only the
  owner's own person reaches a turn at all; a second account never does.
- Accepted risk (the default): a stolen or compromised paired phone can run
  local commands on the Mac through the Chief, with no approval, until its
  pairing is revoked. Revoke it in cmux Settings > Server > Devices (the
  relay refuses its new streams at once on `host.revoke`). Turning
  `remote.autoApprove` off on the Mac puts approvals back, which stops a
  prompt injection but not the phone's holder (next item).
- Residual risk: the paired device approves its own requests. Any person
  the gate admits answers the approvals, and that includes the device that
  started the turn. So `ask` stops a prompt injection (content the turn
  reads cannot approve anything) and makes every local effect visible, but
  it does not stop a stolen or compromised paired phone: its holder can
  approve its own turn's requests until the device is revoked. Revocation
  removes it from the relay (new streams refused after 24 hours offline, all
  closed after 72 hours or at once on `host.revoke`).
- Residual risk: `remote.autoApprove` is only as protected as the user's
  files. The host refuses to turn it on during remote-origin work, but any
  local process of the user, and any approve-all local turn, can write
  `optchat/settings.json` directly (the host reads it at its next start).
  With it on (the default), remote-origin turns are as powerful as local
  ones.
- Residual risk: an approval is full authority for the shown call. An
  approved command can start a background process that outlives the turn,
  or start an acpmux session directly with another policy (outside `chief
  agents` and `spawn`).
- Access to unowned objects. The gate opens nothing: the relay already
  scopes every id to conversations that list the install, and the Chief
  answers and asks only in the conversation the message came from.
- Local-state exposure. Replies and approval questions go to that
  conversation, which the device already reads. An approval question shows
  the requested call's input (up to 1,000 characters), and a turn's reply
  can include local state (file contents, command output) as it does for a
  local message: the same exposure the device already has as a participant.

Tests: `tests/remote_wake.rs` (every refusal above, the mention rule, and a
device message logged and answered end to end) and `tests/remote_policy.rs`
(a remote turn cannot run a shell without an approval, zoom needs none, the
approver is traced; a remote turn cannot turn on `remote.autoApprove`; a
mixed-origin turn stays `ask`; a local turn keeps approve-all; a child
spawned from an `ask` turn asks too, and its shell call waits for a person).

## Deviations from the spec

Taelin's updated recipe (gist 3c190e0, 2026-10-08) is followed for the view
(due from the pair's last message, the 128 KB -> 64 KB sawtooth, the view
saved at every message and never rebuilt), the compaction view (16-32 KB),
the compaction order (8 message nodes ahead, a ready queue), the one system
prompt for turns and compactions, the task texts with the 512-dash ruler,
the Too long retry, the 4-line cache blocks and single-flight. The replay
test `optchat-core/tests/cache_replay.rs` pins the cache rate: turns 99.3%,
compactions 98.1% of their prefix (spec: 98.6% and 96.2%). What differs:

- **Claude Code compactor tools.** Compactions send the turns' system text,
  but a compactor session keeps `--tools ""` and deny-all (isolation), so
  on the Claude Code route its tool prefix differs from the turns' and it
  does not read the turns' entry; compactions still read each other's.
  The native engine with the API compactor sends the same system and tools
  (tool_choice none).
- **Kinds.** The log keeps `talk` for the agent's replies (the spec renames
  it after the agent) and logs a subagent's report as a `user` message
  starting "[id] " (the spec's `work`): old nodes say `talk:` forever, and
  an older binary refuses an unknown kind. The prompt names both.
- **System prompt.** No paragraph on computers (no device tools), no
  `zoom("Name")`; the mid-turn line says a message interrupts at once.
- **view.json** is the `memory/checkpoint` state row of the SQLite store,
  written after every message.
- **Single-flight** releases waiting calls at the writer's response start
  (on acpmux: its first streamed output), and the prefix then counts as
  written for 5 minutes, so later calls on it go at once.
- **Model.** The compactor runs Claude Haiku 5.5 at high effort
  (`OPTCHAT_COMPACTOR_MODEL`, `OPTCHAT_COMPACTOR_EFFORT` or engine.json's
  `compactor-model` pick another). An account without the model builds
  with the turn model, logged once. Haiku and the turns' model have
  separate cache entries, so compactions read only each other's.
- **Width.** JOBS and AHEAD are 64 (spec: 8): 64 calls of about 1 s stay
  under 4,000 requests a minute. The acpmux compactor runs at most 16
  sessions (Claude Code processes on one sticky account); the rest wait.
- **Long messages.** A message over 200,000 characters is still logged
  whole and cut in its compaction call only (STEP_MESSAGE), not split.
- **Failed compactions** are retried after the fixed 10 s wait (and at the
  next pump), not only at the next message.
- **acpmux engine: cache marker.** Claude Code places 3 of the 4
  breakpoints, so a turn adds one, on the last whole 4-line block; codex
  has only automatic prefix caching (see Harnesses and cache layout).
- **Messages during a turn (section 7, MASTER).** The spec delivers them at
  the next tool boundary; here a human message interrupts at once (see the
  top of this file), and MASTER's line says so. On the acpmux engine the
  interrupted turn ends and a fresh one starts. Children's reports do not
  interrupt: the native engine delivers them between tool calls, the acpmux
  engine at the next turn. The brain-host contract has no user cancel, so
  neither engine can cancel a turn or the compactor wait on request; a turn
  past its limit is stopped.
- **cmux routing.** Every turn, the native bash tool, the acpmux daemon the
  host starts and each child's preset carry `CMUX_TUI_SOCKET` and
  `CMUX_MUX_SOCKET` set to the app's daemon (`CMUX_APP_DAEMON_SOCKET`, else
  `--daemon-socket`) and the bundled `cmux` first on PATH (src/cmux_env.rs).
  Without them the CLI guessed the untagged app from `CMUX_SOCKET_PATH` and
  a tagged build's Chief created workspaces in the user's release app.
- **Native engine: the bash tool.** Each command is its own `bash -c` (so a
  timeout kills all it started); the working directory carries over between
  commands, shell variables and exports do not. Tools are approve-all, like
  the acpmux engine's default policy; the text editor is not confined to a
  root. No MCP servers: the `cmux` CLI and `chief agents` run from bash.
- **Native engine: refusals.** A refused turn says so. Server-side
  `fallbacks: "default"` is off by default (`OPTCHAT_CHIEF_SERVER_FALLBACK`):
  the team subrouter may not forward its beta header.
- **Compactor through acpmux (section 4.2, 8).** In the cached layout the
  compactor's system text and the context's first piece are the session's
  system prompt (Claude Code's default prompt is replaced), and the context
  carries one breakpoint (100k) where the spec has three (50k, 80k, 100k):
  Claude Code keeps three of the four for itself (see Compactor cache). In
  the old layout (an acpmux without preset args) Claude Code's own system
  prompt (with its date and environment lines) comes first, the compactor's
  system text is the first block of the user prompt, the context pieces
  carry no breakpoints, and each node pays for its whole view at the cache
  write price. Measured live, see Cost and Compactor cache above. Each node
  also pays a harness start.
  Effort is `medium` on both routes, as section 4.2 says: acpmux passes it
  to Claude Code as `--effort medium` and to codex as `reasoning_effort`;
  another harness family keeps its default (`OPTCHAT_COMPACTOR_EFFORT`
  overrides; not yet measured live). Size-loop retries
  stay in the same session, so the earlier reply (thinking included) stays
  in the harness's context, as section 8 wants, though the host never sees
  the blocks.
- **Huge messages (section 4.2, rule 3).** The spec sends a message whole to
  its compactor call; a paste or tool input larger than the model's context
  fails that node on every try, and rule 3 then blocks every later level-0
  node and every turn. A message longer than `STEP_MESSAGE` (200,000
  characters) shows only its first and last 100,000 characters in that one
  call (the log keeps it whole, and `zoom(id, 1)` returns it whole), and its
  line starts with `(cut: N of M characters unread) `, which the host adds.
  The model is told its reduced room (512 bytes less the prefix), and the
  size loop measures its reply against that room, so the finished line fits
  in 512 bytes like any other; only after five tries does the shortest
  reply win, as for every node. The limit counts characters, so a cut CJK
  message can still be large in tokens (about 200k characters stays inside
  the context of the compactor models in practice, but is not checked). The
  WebAssembly build exports the cut: `compactRequest` returns `cut` and
  `room`, `sizeCheck(tries, room)` measures against the room, and
  `finishLine(cut, line)` adds the prefix.
- **Compactor refusals (section 4.1).** A node the compactor model declines
  is built by `claude-sonnet-5` (fewer safeguard categories) instead of
  being retried forever. On the acpmux route a refusal arrives as acpmux
  sends it: a JSON-RPC error (code -32603) whose message is Claude Code's
  refusal text, which always links `anthropic.com/legal/aup`; a usage limit
  or an overload is not a refusal and is retried. Other failures retry every 10 s forever, as the spec
  says; after a minute of waiting the conversation hears which line fails.
- **Subagents (section 9).** `spawn`/`tell` follow the spec (see Subagents);
  `tell` lands after the subagent's current turn. The older `chief agents`
  children (named, any harness) still work and report alone, one
  `[name] reply` per ended turn; the prompt no longer advertises them.
- **Free nodes and JOBS (section 4.1).** The spec's pump returns as soon as
  JOBS calls run, before it looks at any node. Ours still builds free nodes
  (a short message verbatim, two children that fit together) when JOBS
  model calls run: JOBS caps compactor calls, and a free node makes none.
  The tree and the view are the same; only free nodes are not delayed.
- **Compactor reply (section 4.3).** The spec only trims the reply. On the
  acpmux route a lead-in line before the summary ("Here is the line:", a
  line that ends with a colon and has no other `: `) is dropped too
  (`strip_preamble`): Claude Code and the model sometimes write one, and it
  would become part of a permanent line.
- **System prompt (section 7.2).** Between VIEW_DOC and the user's own
  AGENTS.md there is a short cmux section (how to drive cmux, the subagent
  commands, the memory tools by name or path). It names no user and holds
  nothing per turn. The spec has the user's instructions file there; the
  section is what any cmux user would otherwise have to write into it.
- **Tool results inside an acpmux turn (section 7, CAP).** Every logged
  `echo` is capped at CAP. Inside an acpmux turn the harness resends its
  own tool result to the model, at its own size limits (Claude Code cuts
  long outputs itself), which the host cannot change; the native engine caps
  before it resends, as the spec says.
- **Who is logged (section 2: "every message").** Only human messages that
  wake the Chief are logged (`wake::chief_wakes`): in a group conversation a
  message without a mention is not. A message from the user's own paired
  device wakes and is logged (see Remote-origin messages); any other device
  message is refused. Non-text parts are not logged on this branch.
- **What the user sees (section 7, "show it").** Home gets each turn's last
  reply only; earlier replies and tool steps are in the memory (and in
  `browse`), not posted.
- **Reply keys.** `turn:optchat:<first id>:<its stamp>`: the stamp keeps keys
  unique after a memory reset or a restored backup.

## Always-on brain (cloud conversation source)

Design: `brains/DESIGN-cmux-lawrence.md` in the OptChat lab. The host can answer the
chief's CLOUD main conversation instead of the app's local one, so the Chief keeps
running when the laptop sleeps and every device sees it through its cloud Home source:

```
optchat-chief host --conversation-source cloud --cloud-install FILE --daemon-socket PATH --mux-home DIR
```

It connects to a cmux-tui daemon of its own that has `cloud-conversations-v1`
(feat-cmux-next), leases a chief token to it (`cloud-session-set`), subscribes to the
chief's main conversation and answers as `agent_<chief>`; inside the brain that id is
`agent_mux`, so the wake rule, cursor and outbox are unchanged (`src/cloud/idmap.rs`).
The token lives 600 s and is renewed 150 s before it expires and on
`cloud-session-needed`. The lease is daemon-wide: every unbound client of that daemon
acts as the chief, so never point it at a shared daemon.

Identity (once per brain host; the install key never leaves `install.json`, 0600). The
brain pairs like a cmux server (plans/cmux-next/server.md 6.2), so no session token
reaches it:

```
optchat-chief cloud pair   --install $B/cloud/install.json --api-base https://<api origin>
optchat-chief cloud status --install $B/cloud/install.json     # mints a test chief token
```

`cloud pair` makes the P-256 install key and a WireGuard key, proves the key to
`POST /v1/pair/begin`, and prints a code and four check words (never the collect
secret). In the cmux app, "Server > Add Server…" takes the code, shows the same words,
and approves it: `server.pair.approve` registers the key under the user as a `daemon`
install and adds the host to the team. The brain hears the result on the
`/v1/pair/wait` WebSocket, then waits (`--wait-chief`, default 300 s) for the app to
place a chief on it (`brain_place: {host, install}` in `chief.list`); only that chief's
token gets the rights a brain needs. `--chief default` falls back to the default chief
when none is placed (a backend without `brain_place`). A paired file without a chief
resumes at the chief step when `cloud pair` runs again.

Fallback without the app (a session token once, from where the Stack session lives):

```
optchat-chief cloud enroll   --install $B/cloud/install.json --api-base https://<api origin>
CMUX_CLOUD_SESSION_TOKEN=<the user's session token> \
optchat-chief cloud register --install $B/cloud/install.json     # install.register (session only)
optchat-chief cloud chief    --install $B/cloud/install.json --create   # default chief + main conversation
```

Memory move (both hosts stopped; `--seal` last):

```
optchat-chief memory export --mux-home OLD --out chief-memory.tar --seal
optchat-chief memory import --mux-home NEW chief-memory.tar
```

The archive is a git bundle of `optchat/chat/` (messages and summaries), AGENTS.md and a
manifest; host.json does not move. A sealed home (`optchat/MOVED`) never starts a host.

`deploy/brain/install.sh` installs three user LaunchAgents
(`ai.manaflow.chief-brain.{daemon,acpmux,host}`) under `~/.cmux/brains/chief` with
pinned binaries (optchat-chief, cmux-tui, acpmux and the Rust `cmux` CLI, all from one
build; the CLI beside optchat-chief is what the Chief's and its subagents' `cmux` calls run);
`deploy/brain/rollback.sh` removes them and keeps the memory and key.

## Tests

Run them on a Blacksmith Testbox (`skills/blacksmith-testbox/SKILL.md` in a
cmux checkout), in each of optchat-core, optchat-host and optchat-chief:

```bash
umask 022; cargo test --release; cargo clippy --release --all-targets -- -D warnings; cargo fmt --check
```

`tests/brain.rs` runs the brain against in-process fakes of both owners;
`tests/compactor.rs` runs the acpmux compactor route against the fake acpmux
port (one session per node, size loop in it, purge and transcript deletion,
one JOBS gate across main and fallback, refusals as acpmux sends them, the
probe's fallback and isolation checks, per-node token lines, route choice,
the start-up notice, the cached layout's system prompt file and single
marker, the retry without the marker, the old layout without preset args); `tests/audit3.rs` covers interrupts on the acpmux
engine and home-scoped turn names, `tests/native.rs` interrupts on the
native engine;
`tests/harness.rs` covers the harness switch, the Claude turn layout (preset system prompt, one marker, no CLAUDE.md, the 4-breakpoint rerun, the old layout), the codex turn layout and AGENTS.md, both usage shapes (also when the answer follows `turn_end`), `chief zoom`/`date`, and the `cmux.chief` tags;
`tests/acpmux_wire.rs` (preset args, `systemPrompt` and their feature detection, session tags included) and `tests/daemon_wire.rs` run the real clients against
fake servers on Unix sockets; `tests/lock.rs` runs the binary against a held
lock; `tests/mcp.rs` runs `optchat-chief mcp` against a live test memory;
`tests/crash.rs` aborts a child process (`OPTCHAT_FAULT=<point>[#n]`) at
each transaction boundary of logging a message and folding a turn and
checks that a fresh brain logs each message and step exactly once, and that
an old host.json moves into the database once; `tests/backup.rs` pushes to a
local bare repository (holds on a secret, retries offline, never forces).
In optchat-host, `tests/migrate.rs` migrates `tests/fixtures/old-home`
(written by the line store at 07a17e8a78d) and checks the view, the counts,
the kept files, the byte-identical export and a crash during the migration;
`tests/sqlite.rs` covers search, the incremental export, a reader during
writes and crashes inside an append and a node write; `tests/bench.rs` is
the ignored benchmark above.
