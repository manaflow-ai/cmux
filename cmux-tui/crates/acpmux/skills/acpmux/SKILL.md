---
name: acpmux
description: "Drive coding agents through acpmux, which keeps Claude Code, Codex, OpenCode, pi and Gemini sessions alive by name on this machine and others: run, prompt, wait on or inspect a session, or start a second agent for a subtask (also when ACPMUX_ENV=1). Every command has --json."
---

# acpmux guide

acpmux is tmux for agents. A daemon keeps agent sessions alive; the `acpmux`
CLI and a JSON-RPC socket drive them. Sessions survive your process, keep
their history, and can live on other machines (`machine/name`). The daemon
starts on first use. Print this guide any time with `acpmux guide`
(`--guide`, `--skill`); the binary is the authority: `acpmux --help`,
`acpmux wait --help`, `acpmux session --help`.

## 1. Am I inside acpmux?

```bash
test "${ACPMUX_ENV:-}" = 1 && echo "I am session $ACPMUX_SESSION_NAME ($ACPMUX_SESSION_ID)"
```

When set, `@` names your own session (`acpmux last @`, `acpmux history @`).
Sessions you start are siblings, not children: they outlive you.

To message another session from a chat, use the `send` tool
(`mcp__acpmux__send`, `mcp__cmux__acpmux_send` when cmux lists every tool, or
`cmux.acpmux_send` in a cmux_exec script), not
`acpmux send` in Bash ("Messages between agents" below). For the rest, run
the daemon's own CLI: `"$ACPMUX_BIN"` is one absolute path that runs it, also
inside cmux. Use it in place of `acpmux` in every command, as in
`"$ACPMUX_BIN" last NAME`. The `acpmux` on your PATH can
be another, older build (a login profile puts `~/.local/bin` first). A CLI
older than the daemon does not say who runs it: the daemon records its sends as
an unverified program, not as you or the person, and refuses it what only the
person's terminal may do (`caller.old_client`).

Inside cmux your `cmux-subsessions` MCP server starts children instead:
`start_session` (with `worktree: true` for a worktree of its own, or `fork: true` for a
fork of your own chat that keeps its history),
`list_sessions`, `get_session`, `wait_for_sessions`, `send_message`,
`stop_session` and `retry_session` (a child's failed turn or subagent, again now). Prefer
them when you have them; this CLI is the fallback (`acpmux retry NAME`).
At most `maxRunning` of your sub-sessions run at once (1000 unless the user
changed it); a start past it is queued and starts by itself when one finishes.
`list_sessions` (under `self`) or `acpmux session limits @` shows your limits
and how many run and wait; only the user or your parent session raises them.
A sub-session runs on this machine; `host: "auto"` first checks it has room
(the engine `acpmux new --machine auto` uses) and refuses the start when not.
A lane is different: an agent with its own worktree and brief that reports
back to you and outlives you. Start it with the one launcher command in
section 3 (`acpmux new --worktree … --prompt-file …`), not a hand-made
`git worktree add` + `acpmux send` script.
Start a session only when the user asked for one. If they refuse with "this
session's caller token is not one this acpmux daemon knows", run
`acpmux session restart @`: your agent restarts in the same conversation when
the turn ends, with tools that work again; your sub-sessions keep running.

To open a session's chat for the user, run
`cmux agent open SESSION_ID` (the `cmux` MCP server's `app_agent_open`) for a
new workspace, or `cmux agent open-tab SESSION_ID --target PANE_ID`
(`app_agent_open_tab`) for a tab in a pane you name. Opening a workspace may move focus; a
`start_session` child is also listed under your chat in the chat list. Post progress on a workspace's
sidebar row with `cmux workspace WS status set KEY TEXT`, and ask for
attention with `cmux notify`. `cmux docs search "show the user"` lists the rest.

When a sub-session asks a question (its AskUserQuestion or other ask),
`wait_for_sessions` returns and its row lists it under `questions`. Tell the
user what it asks. Only when the user turned on Settings > Agents >
Sub-sessions > Let Sessions Answer Their Sub-sessions' Questions (off by
default) may you answer one marked `answerable` yourself with
`answer_question` (keys: each item's `id` or `prompt`); otherwise it is
refused (`subsessions.answers_off`, `subsessions.not_a_question`). A
permission request or a plan approval is never a question: only the user
allows it, in cmux NEXT, so tell the user which sub-session waits.

Your own questions follow the same split. The user allows tools through the
chat's mode and the harness's permission prompts, and a chat in Full access
(Claude Code `bypassPermissions`, Codex full access) has already allowed
every tool call its harness would ask about. Never ask the user to allow,
confirm or approve a step, with AskUserQuestion or in text ("allow this?",
"should I go ahead?"): decide, say why in one line, and go on. Deciding never
widens the task: a step a cmux skill keeps for the user's own request
(importing a browser's cookies, deleting their data) waits for that request,
and a cmux consent card (computer use setup) is theirs to answer; leave such
a step out and say so. Ask only about product taste you cannot settle from
the request or the code (how something should look, read or behave), and ask
it as that choice, never as a permission.

## 2. Pick a harness and a model: `-m HARNESS[/MODEL]`

One flag. The head is a family (`claude`, `codex`, `opencode`, `pi`, `omp`, `prime`,
`gemini`) or a profile name; a model may follow the first slash and keeps its own
slashes. Nothing is inferred. A head that is neither is an error, and when it is a
model id the error tells you the spelling to use.

| You want | Write | acpmux does |
| --- | --- | --- |
| a Claude, a Codex, with defaults | `-m claude`, `-m codex` | the family's preferred profile (an account pool, a router) plus its model, effort, policy |
| one exact model | `-m claude/opus`, `-m codex/gpt-5.5`, `-m opencode/zai/glm-5.1`, `-m pi/subrouter/gpt-5.6-sol` | that harness, that model |
| a fork | `-m omp`, `-m prime` | its own family; prime takes no model over ACP |
| a bundle someone named | `-p deepseek`, `-p omx` | the preset's harness, model, effort, policy, env; `-m`/`-e` still win |
| nothing in particular | no flag | the default harness and its defaults |

Read, never guess:

```bash
acpmux defaults               # per family: profile chosen, model, effort, policy
acpmux preset                 # named bundles for -p
acpmux harnesses              # profiles with family and argv
acpmux --json daemon models   # every model id each harness declares or reports; --refresh re-probes
acpmux daemon reload         # reread harnesses/defaults/presets without stopping sessions
```

`daemon reload` is safe while sessions are running: it replaces only catalog-facing
configuration and refreshes short-lived model probes. Existing child processes and turns are
not restarted. If the daemon predates this command, install the new binary and restart it once
when you can safely do so; after that, use reload for configuration changes.

Explicit flags always win: `-m`, `-e low|medium|high|xhigh|max`,
`--policy ask|approve-reads|approve-edits|approve-all|deny-all|review`, `--cwd DIR`,
`--machine MACHINE`. A model the harness rejects fails the creation with the ids it
knows; the session is not created.

## 3. Core loop

From a chat with acpmux's MCP tools, message with the `send` tool, not the
`send` lines below; they are for shells and scripts.

```bash
acpmux run -m codex --cwd ~/proj --policy approve-edits --tag task=fix "fix the failing test"   # create, send, print only the reply
acpmux --json run -m claude "…"                    # {"sessionId","name","reply","stopReason"}
acpmux exec -m claude "…"                          # run, then delete the session
acpmux ensure NAME -m codex --cwd DIR --tag task=review # get it, or create it with a label
acpmux send NAME "next step"                       # the person's send: stream the reply; -q for the final text only
acpmux send NAME "…"                               # from an agent (or with --class): queued here and returns in ms, delivered in the background even while the peer is down; prints the delivery id
acpmux send NAME --wait "…"                        # an agent's send that waits: a question (wakes an idle receiver), steers into a running turn and prints that turn's reply
acpmux send --status [ID]                          # one delivery's state, or every message this daemon still delivers or delivered today
acpmux send NAME --no-wait "…"                     # a message: steers into the running turn when the harness steers (read at its next tool boundary; never stops it), else queues; returns at once
acpmux send NAME --no-wait --no-steer "…"          # queue behind the running turn instead
acpmux send NAME --wait --no-steer "…"             # an agent's send that waits: queue behind the running turn instead
acpmux send NAME --steer "…"                       # the person's send that waits: steer it (it queues by default)
acpmux send NAME --no-wait --supersede KEY "…"     # replace your own prompt still queued under KEY (a correction is never read after the order it corrects); prints "replaced N queued", --json adds replaced and replacedPromptIds
acpmux send NAME --no-wait --notice --severity fire --title "fast tier failed on 3 PRs" --link https://github.com/o/r/pull/1=#1 "body"   # a tool's notice: the chat draws a notice row (severity, sender, title, links); --sender defaults to --from/ACPMUX_FROM/this session
acpmux send MACHINE/NAME "see" --attach shot.png     # send files with it (repeatable; no scp): images reach the agent and transcript as images, other files as a link; saved 0600 on the session's host; any size and number (large ones are uploaded in chunks first)
acpmux last NAME [-n 3]                            # last reply text
acpmux history NAME                                # one line per turn: prompt, status, tools, tokens, wall time
acpmux ls [--all] [--wide]                         # live named lanes + STUCK reason; --all: closed/reviewer/sub/unnamed too; --wide: + context, subagents, 24h cost
acpmux ls [--status running|ready|waiting|idle|closed] [--pending] [--tag k=v] [--live] [--machine MACHINE]   # a filter hides nothing
acpmux --json ls --live --fields name,status,peer  # scripts; bare `ls --json` is every record, thousands on a busy host
acpmux session info NAME                           # model, mode, policy, pending permissions, usage
acpmux session info NAME --fields status,turn.activity   # just those fields (one field: its bare value), no `--json | python3`
acpmux ls 'review-*' --fields name,status          # name globs (`machine/glob` for one machine); --fields takes dotted paths
acpmux send --tag area=X [--dry-run] "…"           # a --no-wait message to every live session with the tag, one line each
acpmux session set NAME model=… | effort=… | mode=… | policy=…
acpmux session fork NAME [--name NEW]              # new session sharing the history so far
acpmux session cancel NAME                         # stop the running turn; the session stays
acpmux session restart NAME                        # restart its agent process after the turn, same conversation
acpmux session resume NAME                         # run the prompts a failed turn held (no person needed)
acpmux session queue list|remove|clear NAME        # its queued prompts; clear --from-agents drops agents' messages only
acpmux session kill --purge NAME                   # delete (only sessions you created)
acpmux session stop NAME --if-idle [--expect-revision LASTSEQ]   # stop only if idle and unchanged; else exit 6, nothing stopped
```

`send` on a busy or blocked session never refuses: the prompt queues and the
output says `queued behind …`.

### Messages between agents

In a chat with acpmux's MCP tools, message with the `send` tool
(`mcp__acpmux__send`; `mcp__cmux__acpmux_send` when cmux lists every tool;
`cmux.acpmux_send` in a cmux_exec script), not
`acpmux send` in Bash: one call, or `messages` for several, with `file`,
`attach`, `class`, `pr`, `notice` and `supersede`, through the same outbox as
`send --no-wait`. The CLI is for shells and scripts.

From inside a session (`ACPMUX_ENV=1`) your send is your session's message, not
the person's prompt. What the receiver gets depends on who you are to it:

| You are | It gets | Wakes it when idle | The reply |
| --- | --- | --- | --- |
| the session that started it or first gave it work | a prompt, its own turn | yes | `send --wait` prints it |
| another session, with `--wait` | a question in its inbox | yes | `send --wait` prints that turn's reply |
| another session, with `--no-wait` | an action in its inbox | no: it goes with its next turn | it answers with `inbox_reply` or the `send` tool |
| another session, `--no-wait --class question` or `block` | a question in its inbox | yes | that turn's report comes back to you (to your subagent, if one asked); not to a session on another machine |
| the person, in a plain terminal | the person's prompt | yes | streamed |

- `--class question` or `block` always wakes the receiver; `result` (an
  action, the `--no-wait` default) only from its starter; `fyi` never.
- A `--wait` send that would not wake an idle receiver (`--class result` from
  a session that did not start it) fails at once with exit 1,
  `send.not_woken`: nothing was delivered. `send --status` says `held in its
  inbox` for such a `--no-wait` message.
- Every agent send prints `sending as NAME` on stderr. A Claude Code subagent
  sends as its lead's session, named `LEAD's TYPE subagent ID`, and so do its
  `acpmux run` and `acpmux new` with a prompt. The reply to its own `run` or
  `send --wait` reaches only it: the lead gets no lane report of that turn.
  Its calls through the MCP tools (`mcp__acpmux__send`, `bg_start`, and cmux's
  `acpmux_send`, `acpmux_bg_start`, `cmux_exec`) name it the same way. The
  report of a turn it asked for without waiting comes to it only after its
  next Bash command or one of those MCP calls: a subagent that makes no such
  call any more does not get it. Once it has ended, the report goes to the
  lead, saying `This report is for your TYPE subagent ID`. If it ended with no
  `SubagentStop` hook, its reports wait until no subagent of the lead runs. The
  end message of a background task it started (`bg_start`, `run_wait`) takes
  the same rule. A cmux workflow it starts (`cmux.cmux_workflow`) runs as it:
  the workflow's commands and its script's sends name it. Its work on another
  machine (an `agent()` or `machine()` with `on: HOST`, a CI machine) still runs
  as the lead. On a path that names no subagent, a subagent passes
  `notify: false` and reads the task with `bg_output`. The receiver reads
  `From another agent (LEAD's TYPE subagent ID)` and ends its turn with its
  answer; it does not send it to the lead.
  A subagent's send that goes to the send relay (`sendRelay`: no session here
  or on a peer) names the subagent to the relay as a label only
  (`ACPMUX_FROM_SUBAGENT`, `ACPMUX_FROM_LABEL`). Both are unverified claims:
  nothing on the far side can check them yet. A Codex subagent's relayed send
  has no label. `ACPMUX_FROM` stays the lead's name, the one reply address the
  relay has, so the far side's answer reaches the lead, not the subagent.
  The `send` tool (`to: LEAD`) reaches the lead.
  A Codex subagent is named `LEAD's codex subagent THREAD` (its own
  `CODEX_THREAD_ID`); when acpmux does not know the lead's thread, the line
  says `LEAD (subagent identity not available for codex)`.
- An agent keeps its proven identity across a daemon restart or update: the
  daemon keeps digests of its caller tokens, so `no proven session` after a
  restart is a bug, not a step to fix by hand.
- An inbox notice ends with how to reply. Answer in your turn, with
  `inbox_reply` or the `send` tool (`acpmux send NAME` without them); never
  with your harness's own SendMessage, which reaches no acpmux session.
- In a Claude Code agent acpmux started, Claude Code's own cross-session
  messaging is off (no `ListAgents`; its peer list was every Claude Code on the
  machine, other daemons' too, and a message it held showed nowhere).
  `SendMessage` to an acpmux session is refused with the command to use:
  `"$ACPMUX_BIN" send NAME --wait "…"` (its reply in this turn) or the `send`
  tool. `SendMessage` still reaches your own subagents. `acpmux ls` is the peer
  list. A profile that sets `CLAUDE_CODE_HARBOR_KITE` itself keeps its value.
  That variable is an undocumented Claude Code switch: if a later Claude Code
  renames it, `ListAgents` may list other Claude Code sessions again, but the
  refusal above still applies.
- `wait` right after `send --no-wait` waits for the turn the message brings;
  it never answers with the idle state from before the message.

A Claude Code session acpmux did not start (the Claude desktop app's Code tab,
a terminal `claude`) takes a stable name from its own shell (a Codex thread gets
one by being started with acpmux):

```bash
acpmux register desktop-zoe            # in its Bash tool; then run the --code line it receives
acpmux send --no-wait desktop-zoe "…"  # from any machine that peers this one: queued, retried, --status
```

The daemon checks who runs the shell by the kernel's process tree, never by
what you type. A Claude Code session's message opens with its own
`CLAUDE_CODE_MESSAGING_TOKEN` (the inbox Claude Code documents for a script or
hook) and arrives as another session's message, under its inbound rules. While
the app is closed the message waits as `bridge.not_running`; register again
after the session restarts. Which harness can send, receive, steer and wake:
`cmux-tui/crates/acpmux/docs/address-book.md`.

Start an agent for a task (its own worktree and brief) with one command; running
it again reuses the session and worktree and sends nothing:

```bash
acpmux new -n NAME --worktree REPO[@BASE] --prompt-file BRIEF.md --report-to ME -d
```

Name a session after its task: a short readable title in 2-5 words
(`-n session-info-drag-handles`), never an id or a
counter (`cloud-item-14`, `optchat-sub-6b68ac4a-a26`). People read it in the cmux
sidebar and in `acpmux ls`. Keep ids, item numbers and bead ids in a tag
(`--tag item=14`). `new` and `ensure` print a one-line hint for a name that reads
as an id; it is never refused and still works as an address. A `Title: ...`
first line in the prompt titles the chat.

`--group "GROUP"` is optional person-facing app state. It runs `cmux agent
open`, creates a workspace and places it in the named cmux sidebar group (and
may create that group); it does not move focus. Use a human label only, never a
`grp_…`, `ws_…` or other object id (refused with exit 2, `usage.group_name`).
The app matches the name ignoring case and outer spaces, so `"gui push"` joins
an existing "GUI push" group. Omit it unless the person asked for this
sidebar placement. To recover from an unwanted placement, inspect
`cmux --json workspace group list`, then move/delete the affected workspace or
group with the other `workspace group` commands; rerunning without `--group` is safe.

A child of another harness under your own chat (a Codex child of a Claude chat): it lists
under your chat, and your sub-session tools read, message and stop it.

```bash
acpmux run --parent "$ACPMUX_SESSION_ID" -m codex -e high "PROMPT"   # prints its reply
acpmux new --parent "$ACPMUX_SESSION_ID" -m opencode -n tests -d "PROMPT"
```

Never script `git worktree add` + `acpmux new` + `acpmux send` by hand. Which
surface for what (CLI, `cmux-subsessions` MCP, cmux MCP): `cmux-tui/crates/acpmux/docs/agent-surfaces.md`
in the cmux repository.

## 4. Wait for things

```bash
acpmux wait                                  # ANY running session resolves: turn ended (exit 0) or permission pending (exit 2)
acpmux wait A B --all --timeout 600 --print  # every named session, print each last reply (a failed turn: its error and retry, exit 1)
acpmux wait NAME --until running             # the prompt was accepted
acpmux wait NAME --until done                # turn ended while no client was attached
acpmux wait NAME --match "tests pass"        # or --regex; existing text matches at once
acpmux session tail NAME --since CURSOR -f   # raw events as JSON lines; cursor = sessionId:seq
```

Exit 3 is a timeout. A timeout or `prompt_stalled` does not prove the prompt
was not delivered: run `acpmux last NAME` and `acpmux history NAME` before
sending it again. Add `--timeout` to `send`/`run` to cancel a runaway turn
cooperatively.

To try a build or a daemon restart, use a daemon of your own, never the one
every session on this machine shares. Point `ACPMUX_HOME` and `ACPMUX_SOCKET`
at a folder you made (acpmux never creates a missing `ACPMUX_HOME`). Unset every
other `ACPMUX_*` variable and Claude Code's `CLAUDE_CODE_MESSAGING_*` there: they
name your own session, its token and its daemon, so your sends would be your
session's (or go to the shared daemon) and not the person's. The first command
starts the daemon in the background by itself (detached; no background shell
needed). A new home has no `defaults`: set the profile you want (`claude-sr2`
for sr2), or `-m claude` runs plain `claude`.

```bash
X=/abs/path/to/acpmux                       # the build you try (in a session, "$ACPMUX_BIN" is its daemon's)
mkdir -p /tmp/try-acpmux
for v in $(env | grep -oE '^(ACPMUX|CLAUDE_CODE_MESSAGING)_[A-Z0-9_]*'); do unset "$v"; done
export ACPMUX_HOME=/tmp/try-acpmux ACPMUX_SOCKET=/tmp/try-acpmux/acpmux.sock
$X defaults claude prefer=claude-sr2,claude  # as the shared home has it (`acpmux defaults` there)
$X daemon status                            # starts it; this home's sessions and live agents
$X daemon restart                           # the new daemon adopts every live agent; they keep their conversation
$X daemon shutdown --end-agents             # done: end its agents too, then rm -rf /tmp/try-acpmux
```

## 5. Permissions

```bash
acpmux pending                               # every pending request, and how to answer it; also messages a chat's Claude Code holds
acpmux session deny NAME                     # allowing is the cmux app's alone (the chat's permission card)
acpmux session rules NAME '{"autoDeny": ["rm -rf"], "ask": ["execute"]}'
acpmux run --on-permission deny|fail …       # never hang a script on a prompt (fail = exit 5)
```

`acpmux pending --json` gives each request a `needsYou` link
(`cmux://needs-you/<permissionId>`). Put it in a reply to point the user at an
open ask instead of restating it; cmux draws it as a chip that opens the ask in
its Needs you list. Its `heldMessages` lists another session's message that a
chat's Claude Code holds instead of reading it (`session`, `fromName`, `from`,
`cause`, `messageUuid`, `heldAt`; also `heldMessages` of `session info`). Claude
Code gives acpmux no way to release it: it waits for that chat's approval or
expires, so have the sender send it with `acpmux send` instead. acpmux keeps
held messages in memory only: after a daemon restart they no longer show.

Show UI instead of describing it. A reply in cmux draws `![alt](/abs/path.png)`,
a bare image path (`.png`, `.jpg`, `.gif`, `.webp`), a `file://` URL or an
https image address (a PR's `pr-media` link) as a thumbnail that opens full
size on click. Two images in one paragraph, such as
`![Before](/tmp/a.png) ![After](/tmp/b.png)` or `Before: /tmp/a.png` and
`After: /tmp/b.png` on two lines, sit side by side. `#N`, `owner/repo#N`,
`hq#N`, commit SHAs and `path/to/file.ts:42` become links.

`--policy ask` sends every request to a human or to you; the other policies
answer locally. For a reviewer, use `--policy review`: reads, searches and
read-only shell commands (`git log`, `git diff`, `git show`, `grep`, `rg`,
`ls`, `cat`, `sed -n '1,40p'`) run without asking, and every write or other
command is denied at once, so the reviewer never waits for a person:
`acpmux run -m claude --cwd ~/proj --policy review "review the diff of HEAD~1"`.
A build or test run writes, so review cannot compile: give the reviewer the
build output, or run it in a lane with `approve-edits`. Rules sit above the policy and match tool kind, title, and
name, case-insensitively. File writes a harness delegates to acpmux (ACP
`fs/write_text_file`) are gated the same way and show as `Write PATH [edit]`.

A session you start from inside your own session (`acpmux new|run`, a local
`dispatch`, `--parent`, `start_session`) inherits your policy and mode when you
pass neither: your policy, and your mode (or, on another harness family, the
same level: full access, asking, or its own mode). It never runs wider than
you: a wider `--mode` is refused. A start from a plain shell with no session
gets the defaults. Some requests still ask in full access, because the harness
raises them itself (Claude Code's guard on an `rm` whose target it cannot
resolve): your policy answers those, and `ask` sends them to a person.

A policy narrower than approve-all holds or the chat does not run: the start
fails, or a live agent stops, with `policy_unenforceable`. It holds through
acpmux's own Claude Code gate, a harness mode that asks, OpenCode asked to ask,
or an ACP agent that says at `initialize` that it asks before every tool call
(`agentCapabilities._meta.acpmux.asksBeforeTools: true`). acpmux believes that
claim only from an agent it started from a harness entry of its own config
(`config.json` or a discovered harness), and only while that entry still has
the argv and env the agent started with. It does not believe it from a folder
profile (`.cmux/harnesses/*.toml`, which the repository supplies), from an
entry changed or removed after the start, or from a fork or moved chat that
has a copy of another agent's claim. Each claim is in the session events as
`asks_before_tools_claim`, with `trusted` and, when false, `reason`
(`not_started_here`, `not_a_config_entry`, `entry_changed`); see them with
`acpmux session tail NAME`.

## 6. Other machines

A session on another machine is named `MACHINE/NAME` (`big-red/review-42`), and every command takes that
form. A bare name (`review-42`) or an id prefix also works when exactly one live session on this
machine or the machines you added has it; when several do, the command refuses and prints the exact
`MACHINE/NAME` command for each, so pick one and run it. A name in another case (`td2-a` for
`td2-A`), a unique prefix of it or the name without `-`, `_` and spaces works too, and so does a
machine named that way; several matches are refused with each one, never guessed. Say and pass `MACHINE/NAME`: never ask the
person for a session id.

```bash
acpmux machine status                            # each machine: reachable, round trip, disk, load, build
acpmux machine pick                              # which machine new work would go to, and why
acpmux run -m claude --machine MACHINE "…"       # start there; --cwd is a remote path
acpmux ensure NAME -m codex --machine MACHINE
acpmux send MACHINE/NAME "…"                     # wait, tail, history, cancel work the same
acpmux wait                                      # covers remote sessions too
acpmux resolve 'https://cmux.com/deeplink/agent?harness=claude&session=…&host=…'
                                                 # the session a PR footer's link (or an id, machine/name, name) names, here or on another machine: machine, ids, model, cwd, lane, PRs, last turn
acpmux bead link NAME cx-cus7j.230               # the tracker bead NAME works on; `bead ls cx-cus7j.230` finds NAME, `bead ls --session NAME` lists its beads
```

- **cmux Cloud machines.** A Cloud machine's chats run in that machine's own acpmux, which is not
  one of this Mac's machines. From the Mac, `cmux cloud start-chat --prompt TEXT --wait --json`
  starts a chat there, sends the prompt and answers the reply with its `machine_id` and
  `session_id`; its `follow_up` commands send, wait and read on through `cmux cloud exec`.
- **Old spellings.** `acpmux host` (and `hosts`, `peer`), `host place`, `host vm-host` and
  `--host` still work; `machine`, `machine pick`, `machine dedicated` and `--machine` are the names.
- **Check first.** Run `acpmux machine status` before remote work and after any request to a
  machine fails. Don't guess from a timeout. It names the next command for a machine it cannot reach
  (`acpmux machine doctor MACHINE`) and for one on another build (`acpmux machine update MACHINE`, or its
  target-specific `--binary-dir DIR` form when the machine differs). The
  update restarts that machine's daemon: run it only when the task asks for it (see below), and
  otherwise report the version mismatch.
- **Unreachable machine.** acpmux reconnects by itself. A request refused as unreachable was not
  sent, so send it again once `machine status` shows the machine reachable. Its sessions show
  `unreachable` meanwhile; don't start a replacement elsewhere unless the task can't wait.
- **Where files live.** A remote session reads and writes that machine's disk. `--cwd` and
  `--worktree` are paths there, and its worktrees go to `~/.cmux/worktrees/<project>/<name>`
  on that machine. Nothing it writes appears here unless it pushes it (git) or you fetch it.
- **Moving a session.** `acpmux session move SESSION... --machine MACHINE` (or `--machine auto`,
  `machine pick`'s choice, never a reserved machine; `--all-idle` for every idle chat here) moves chats from
  this machine to another one you added, with their history, queue and draft. A chat's worktree branch is
  pushed and checked out there as a fresh worktree; uncommitted changes refuse the move unless
  `--leave-dirty`. A running turn refuses it unless `--interrupt`. `--dry-run` says where each
  would go. The copy left here never runs again and `resolve` points at the new one.
  `--from MACHINE` moves chats that are on another machine, driven from here over ssh to both
  ends (they need not reach each other), and `--machine local` brings them here. The agent's own
  transcript goes with the chat (Claude Code, Codex, pi files; OpenCode as its export), so it
  resumes with its full context; other agents resume from the chat's history.
  `acpmux session export MACHINE/NAME` fetches a bundle to `~/.acpmux/bundles/`, and
  `acpmux session import DIR` restores a copy on this machine.
- **What the machine allows.** Some machines are not for builds or long jobs. When the task or the
  session's first message names what a machine must not run, honour it, and pick another one
  from `machine status`.

A remote start runs under that machine's rules. `--cwd` must sit inside its
`webRoots` (a missing folder there is made); with no `--cwd` the session gets a
scratch folder. `--mode` is refused, and the session starts in the harness's
asking mode. `--policy approve-all` passes only when that machine serves this one
as a peer (`servedAs` in `acpmux --json machine ls`); otherwise start it on that
machine itself, `ssh HOST 'acpmux new … --policy approve-all -d'`, and drive it
from here as `MACHINE/NAME`. Every such refusal ends with the command that works
(`--json`: `error.data.try`, with `error.data.reason`): run that, do not guess.

`machine setup HOST` installs a daemon over ssh; `machine update --all` pushes the
current binary (`--if-idle` leaves a machine mid-turn alone; a daemon that does not
come back on the new build is rolled back). Only do either when the task asks
for it.

## 7. Output

Put `--json` before the command: `acpmux --json ls`. Errors under `--json`
are one object on stderr, `{"error": {"code", "detail", "message",
"sessionId", "retryable"}}`, and nothing on stdout. `--suppress-reads` blanks
read-tool payloads in event output.

Exit codes: 0 ok · 1 runtime or agent error · 2 usage, or a permission is
waiting (`wait`) · 3 timeout · 4 no such session · 5 every permission in the
turn was denied · 6 `session stop --if-idle` refused (`busy` or
`revision_moved`; `error.data.revision` is the current `lastSeq`) · 130 interrupted.

## 8. Rules

- Read ids and names from `--json` output. Never guess them. `new --json` and
  `ensure --json` leave out the command, tool and option catalogs; add `--full`
  for the whole record.
- `wait` with no flags is enough. Add `--until` only for a state-specific step.
- `-m HARNESS[/MODEL]` is the target. Pass a model, `-e`, or `--policy` only when the
  task needs something other than the defaults. Prefer a preset when one exists.
- Name sessions for the task (`ensure review-pr-42`) so a later step or another
  agent can find them. Tag them (`session tag NAME task=review`) when many run.
- Do not delete sessions you did not create. Do not change defaults, presets, or machines
  unless the task is about them.
- `--current` / `@` targets your own session only when `ACPMUX_ENV=1`.
- To hand another session an image (a screenshot, a mockup), attach the file:
  `acpmux send NAME --no-wait "…" --attach /abs/shot.png`, or `attach` in the MCP
  `send` tool. It shows as a preview. Never pass a provider's own file id
  (ChatGPT's `libfile_…`, an upload id): nobody here can open one.
