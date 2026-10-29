---
name: acpmux
description: "Drive coding agents through acpmux, a daemon that keeps ACP agent sessions (Claude Code, Codex, OpenCode, pi, Gemini) alive as named sessions on this machine and on ssh peers. Use when a task says to run, prompt, wait on, or inspect an acpmux session, when ACPMUX_ENV=1, or when you need a second agent (a Claude, a Codex, an open model) for a subtask. Every command has --json."
---

# acpmux guide

acpmux is tmux for agents. A daemon keeps agent sessions alive; the `acpmux`
CLI and a JSON-RPC socket drive them. Sessions survive your process, keep
their history, and can live on other machines (`host/name`). The daemon
starts on first use. Print this guide any time with `acpmux guide`
(`--guide`, `--skill`); the binary is the authority: `acpmux --help`,
`acpmux wait --help`, `acpmux session --help`.

## 1. Am I inside acpmux?

```bash
test "${ACPMUX_ENV:-}" = 1 && echo "I am session $ACPMUX_SESSION_NAME ($ACPMUX_SESSION_ID)"
```

When set, `@` names your own session (`acpmux last @`, `acpmux history @`).
Sessions you start are siblings, not children: they outlive you.

Inside cmux your `cmux-subsessions` MCP server starts children instead:
`start_session` (with `worktree: true` for a worktree of its own),
`list_sessions`, `get_session`, `wait_for_sessions`, `send_message`,
`stop_session` and `retry_session` (a child's failed turn or subagent, again now). Prefer
them when you have them; this CLI is the fallback (`acpmux retry NAME`).
At most `maxRunning` of your sub-sessions run at once (16 unless the user
changed it); a start past it is queued and starts by itself when one finishes.
`list_sessions` (under `self`) or `acpmux session limits @` shows your limits
and how many run and wait; only the user or your parent session raises them.
A sub-session runs on this machine; `host: "auto"` first checks it has room
(the engine `acpmux new --host auto` uses) and refuses the start when not.
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
`--policy ask|approve-reads|approve-edits|approve-all|deny-all`, `--cwd DIR`,
`--host PEER`. A model the harness rejects fails the creation with the ids it
knows; the session is not created.

## 3. Core loop

```bash
acpmux run -m codex --cwd ~/proj --policy approve-edits --tag task=fix "fix the failing test"   # create, send, print only the reply
acpmux --json run -m claude "…"                    # {"sessionId","name","reply","stopReason"}
acpmux exec -m claude "…"                          # run, then delete the session
acpmux ensure NAME -m codex --cwd DIR --tag task=review # get it, or create it with a label
acpmux send NAME "next step"                       # stream the reply; -q for the final text only. From an agent it steers into a running turn and prints that turn's reply
acpmux send NAME --no-wait "…"                     # a message: steers into the running turn when the harness steers (read at its next tool boundary; never stops it), else queues; returns at once
acpmux send NAME --no-wait --no-steer "…"          # queue behind the running turn instead
acpmux send NAME --no-steer "…"                    # an agent's send that waits: queue behind the running turn instead
acpmux send NAME --steer "…"                       # the person's send that waits: steer it (it queues by default)
acpmux send NAME --no-wait --supersede KEY "…"     # replace your own prompt still queued under KEY (a correction is never read after the order it corrects); prints "replaced N queued", --json adds replaced and replacedPromptIds
acpmux send PEER/NAME "see" --attach shot.png     # send files with it (repeatable; no scp): images reach the agent and transcript as images, other files as a link; saved 0600 on the session's host; any size and number (large ones are uploaded in chunks first)
acpmux last NAME [-n 3]                            # last reply text
acpmux history NAME                                # one line per turn: prompt, status, tools, tokens, wall time
acpmux ls [--status running|ready|waiting|idle|closed] [--pending] [--tag k=v]
acpmux session info NAME                           # model, mode, policy, pending permissions, usage
acpmux session set NAME model=… | effort=… | mode=… | policy=…
acpmux session fork NAME [--name NEW]              # new session sharing the history so far
acpmux session cancel NAME                         # stop the running turn; the session stays
acpmux session restart NAME                        # restart its agent process after the turn, same conversation
acpmux session resume NAME                         # run the prompts a failed turn held (no person needed)
acpmux session kill --purge NAME                   # delete (only sessions you created)
```

`send` on a busy or blocked session never refuses: the prompt queues and the
output says `queued behind …`.

Start an agent for a task (its own worktree, its brief, shown in the app) with
one command; running it again reuses the session and worktree and sends nothing:

```bash
acpmux new -n NAME --worktree REPO[@BASE] --prompt-file BRIEF.md --report-to ME --group "GROUP" -d
```

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

## 5. Permissions

```bash
acpmux pending                               # every pending request, and how to answer it
acpmux session deny NAME                     # allowing is the cmux app's alone (the chat's permission card)
acpmux session rules NAME '{"autoDeny": ["rm -rf"], "ask": ["execute"]}'
acpmux run --on-permission deny|fail …       # never hang a script on a prompt (fail = exit 5)
```

`acpmux pending --json` gives each request a `needsYou` link
(`cmux://needs-you/<permissionId>`). Put it in a reply to point the user at an
open ask instead of restating it; cmux draws it as a chip that opens the ask in
its Needs you list.

Show UI instead of describing it. A reply in cmux draws `![alt](/abs/path.png)`,
a bare image path (`.png`, `.jpg`, `.gif`, `.webp`), a `file://` URL or an
https image address (a PR's `pr-media` link) as a thumbnail that opens full
size on click. Two images in one paragraph, such as
`![Before](/tmp/a.png) ![After](/tmp/b.png)` or `Before: /tmp/a.png` and
`After: /tmp/b.png` on two lines, sit side by side. `#N`, `owner/repo#N`,
`hq#N`, commit SHAs and `path/to/file.ts:42` become links.

`--policy ask` sends every request to a human or to you; the other policies
answer locally. Rules sit above the policy and match tool kind, title, and
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

## 6. Other machines

A session on a peer is named `HOST/NAME` (`big-red/review-42`), and every command takes that
form. Say and pass that name: never ask the person for a session id, and never use a bare id
from another machine (an id names a session only on the machine that runs it).

```bash
acpmux host status                               # each host: reachable, round trip, disk, load, build
acpmux run -m claude --host HOST "…"             # start there; --cwd is a remote path
acpmux ensure NAME -m codex --host HOST
acpmux send HOST/NAME "…"                        # wait, tail, history, cancel work the same
acpmux wait                                      # covers remote sessions too
acpmux resolve 'https://cmux.com/deeplink/agent?harness=claude&session=…&host=…'
                                                 # the session a PR footer's link (or an id, host/name, name) names, here or on a peer: host, ids, model, cwd, lane, PRs, last turn
acpmux bead link NAME cx-cus7j.230               # the tracker bead NAME works on; `bead ls cx-cus7j.230` finds NAME, `bead ls --session NAME` lists its beads
```

- **Check first.** Run `acpmux host status` before remote work and after any host request
  fails. Don't guess from a timeout. It names the next command for a peer it cannot reach
  (`acpmux host doctor HOST`) and for one on another build (`acpmux host update HOST`, or its
  target-specific `--binary-dir DIR` form when the peer differs). The
  update restarts that peer's daemon: run it only when the task asks for it (see below), and
  otherwise report the version mismatch.
- **Unreachable peer.** acpmux reconnects by itself. A request refused as unreachable was not
  sent, so send it again once `host status` shows the host reachable. Its sessions show
  `unreachable` meanwhile; don't start a replacement elsewhere unless the task can't wait.
- **Where files live.** A remote session reads and writes the peer's disk. `--cwd` and
  `--worktree` are paths there, and its worktrees go to `~/.cmux/worktrees/<project>/<name>`
  on that machine. Nothing it writes appears here unless it pushes it (git) or you fetch it.
- **Moving a session.** `acpmux session export HOST/NAME` fetches the bundle to
  `~/.acpmux/bundles/`, and `acpmux session import DIR` restores it on this machine. No command
  moves a session from one peer to another yet. To continue the work on another machine, start
  a session there with `--host` and a `--prompt-file` that says where the work stands (branch,
  PR, next step).
- **What the host allows.** Some machines are not for builds or long jobs. When the task or the
  session's first message names what a host must not run, honour it, and pick another host
  from `host status`.

A remote start runs under the peer's rules. `--cwd` must sit inside the peer's
`webRoots` (a missing folder there is made); with no `--cwd` the session gets a
scratch folder. `--mode` is refused, and the session starts in the harness's
asking mode. `--policy approve-all` passes only when the peer serves this machine
as a peer (`servedAs` in `acpmux --json host ls`); otherwise start it on that
machine itself, `ssh HOST 'acpmux new … --policy approve-all -d'`, and drive it
from here as `HOST/NAME`. Every such refusal ends with the command that works
(`--json`: `error.data.try`, with `error.data.reason`): run that, do not guess.

`host setup HOST` installs a daemon over ssh; `host update --all` pushes the
current binary (`--if-idle` leaves a peer mid-turn alone; a daemon that does not
come back on the new build is rolled back). Only do either when the task asks
for it.

## 7. Output

Put `--json` before the command: `acpmux --json ls`. Errors under `--json`
are one object on stderr, `{"error": {"code", "detail", "message",
"sessionId", "retryable"}}`, and nothing on stdout. `--suppress-reads` blanks
read-tool payloads in event output.

Exit codes: 0 ok · 1 runtime or agent error · 2 usage, or a permission is
waiting (`wait`) · 3 timeout · 4 no such session · 5 every permission in the
turn was denied · 130 interrupted.

## 8. Rules

- Read ids and names from `--json` output. Never guess them.
- `wait` with no flags is enough. Add `--until` only for a state-specific step.
- `-m HARNESS[/MODEL]` is the target. Pass a model, `-e`, or `--policy` only when the
  task needs something other than the defaults. Prefer a preset when one exists.
- Name sessions for the task (`ensure review-pr-42`) so a later step or another
  agent can find them. Tag them (`session tag NAME task=review`) when many run.
- Do not delete sessions you did not create. Do not change defaults, presets, or hosts
  unless the task is about them.
- `--current` / `@` targets your own session only when `ACPMUX_ENV=1`.
