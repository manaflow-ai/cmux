---
name: acpmux
description: "Drive other coding agents through acpmux, a daemon that keeps ACP agent sessions (Claude Code, Codex, OpenCode, pi) alive as named sessions. Use when the task says to run, prompt, wait on, or inspect an acpmux session, or when ACPMUX_ENV=1 and you need a sibling agent. Every command has --json."
---

# acpmux

acpmux keeps agent sessions alive in a daemon and exposes them as named
sessions through the `acpmux` CLI and a JSON-RPC socket. Sessions survive
your process; the daemon starts on first use.

## Am I inside acpmux?

```bash
test "${ACPMUX_ENV:-}" = 1 && echo "session $ACPMUX_SESSION_NAME ($ACPMUX_SESSION_ID)"
```

When set, `@` names your own session: `acpmux last @`, `acpmux history @`.
Without it you can still drive any session on this machine.

## Learn the installed CLI

The binary is the authority. `acpmux --help`, `acpmux session --help`,
`acpmux wait --help`. Put `--json` before the command for machine output:
`acpmux --json ls`.

## Core loop

```bash
acpmux run -a codex --cwd ~/proj --policy approve-edits "fix the failing test"   # create, send, print only the reply
acpmux --json run -a claude "..."                                               # {"sessionId","name","reply","stopReason"}
acpmux ensure NAME -a codex --cwd DIR       # get the session, or create it (idempotent)
acpmux send NAME --no-wait "next step"      # queue and return; the reply says what it is behind
acpmux wait                                 # block until ANY session resolves (turn ended or needs a permission)
acpmux wait NAME [NAME…] --until ready|permission|closed|done|running [--all] [--timeout 300] [--print]
acpmux wait NAME --match "tests pass"       # or --regex; resolves when the transcript contains it
acpmux last NAME [-n 3]                     # the last reply text
acpmux pending                              # every pending permission with option ids
acpmux session allow NAME [OPTION] | acpmux session deny NAME
acpmux history NAME                         # one line per turn: prompt, status, tools, tokens, wall time
acpmux session tag NAME task=review [--ttl 3600]; acpmux ls --tag task=review
acpmux session tail NAME --since CURSOR --follow   # raw events as JSON lines; cursor = sessionId:seq
```

`send` on a busy or blocked session never refuses: the prompt queues (or
steers with `--steer`) and the output says `queued behind …`. Answer
permissions with `pending` and `session allow` when you want the queue to move.

## Exit codes

0 ok · 1 runtime or agent error · 2 usage · 3 timeout · 4 no such session ·
5 every permission in the turn was denied · 130 interrupted. With `--json`,
errors are one JSON object on stderr: `{"error": {"code", "detail", "message"}}`.

## Rules

- Read ids and names from `--json` output. Never guess them.
- `wait` with no flags is enough. Add `--until` only for a state-specific step.
- A timeout or `prompt_stalled` does not prove the prompt was not delivered.
  Run `acpmux last NAME` and `acpmux history NAME` before retrying.
- Do not delete (`session kill --purge`) sessions you did not create.
- Permissions: `--policy ask` sends every prompt to a human or orchestrator;
  `approve-reads`, `approve-edits`, `approve-all`, `deny-all` answer locally.
  `session rules NAME '{"autoDeny": ["rm -rf"], "ask": ["execute"]}'` adds
  per-tool rules above the policy.
- `--timeout` on `send`/`run` cancels the turn cooperatively and exits 3.
  `--on-permission deny|fail` keeps a script from hanging on a prompt.
- `--current` / `@` targets your own session only when `ACPMUX_ENV=1`.
- Sessions on other machines show as `host/name`; commands take that form.
