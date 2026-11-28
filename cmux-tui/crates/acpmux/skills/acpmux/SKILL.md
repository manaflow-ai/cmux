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
acpmux run -m codex --cwd ~/proj --policy approve-edits "fix the failing test"   # create, send, print only the reply
acpmux --json run -m claude "…"                    # {"sessionId","name","reply","stopReason"}
acpmux exec -m claude "…"                          # run, then delete the session
acpmux ensure NAME -m codex --cwd DIR              # get the session, or create it (idempotent)
acpmux send NAME "next step"                       # stream the reply; -q for the final text only
acpmux send NAME --no-wait "…"                     # queue and return; says what it is behind
acpmux send NAME --steer "stop, do X instead"      # interrupt the running turn (when the harness supports it)
acpmux last NAME [-n 3]                            # last reply text
acpmux history NAME                                # one line per turn: prompt, status, tools, tokens, wall time
acpmux ls [--status running|ready|waiting|idle|closed] [--pending] [--tag k=v]
acpmux session info NAME                           # model, mode, policy, pending permissions, usage
acpmux session set NAME model=… | effort=… | mode=… | policy=…
acpmux session fork NAME [--name NEW]              # new session sharing the history so far
acpmux session cancel NAME                         # stop the running turn; the session stays
acpmux session kill --purge NAME                   # delete (only sessions you created)
```

`send` on a busy or blocked session never refuses: the prompt queues and the
output says `queued behind …`.

## 4. Wait for things

```bash
acpmux wait                                  # ANY running session resolves: turn ended (exit 0) or permission pending (exit 2)
acpmux wait A B --all --timeout 600 --print  # every named session, print each last reply
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
acpmux pending                               # every pending request with option ids
acpmux session allow NAME [OPTION]           # or: acpmux session deny NAME
acpmux session rules NAME '{"autoDeny": ["rm -rf"], "ask": ["execute"]}'
acpmux run --on-permission deny|fail …       # never hang a script on a prompt (fail = exit 5)
```

`--policy ask` sends every request to a human or to you; the other policies
answer locally. Rules sit above the policy and match tool kind, title, and
name, case-insensitively. File writes a harness delegates to acpmux (ACP
`fs/write_text_file`) are gated the same way and show as `Write PATH [edit]`.

## 6. Other machines

Sessions on peers show as `host/name` and every command takes that form.

```bash
acpmux host ls                                   # peers, connected or offline, remote build
acpmux run -m claude --host HOST "…"             # start there; --cwd is a remote path
acpmux ensure NAME -m codex --host HOST
acpmux wait                                      # covers remote sessions too
```

`host setup HOST` installs a daemon over ssh; `host update --all` pushes the
current binary. Only do either when the task asks for it.

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
