# acpmux CLI: tasks, processes, worktrees and messages

The commands for the work around sessions: tasks one agent gives another, the background processes
and worktrees agents leave behind, and messages that are not prompts. Each command's `--help` lists
every flag and ends with examples.

## Tasks and briefs

| Task | Command |
| --- | --- |
| Give a session a task with a stop condition | `acpmux task new fix-27310 "Fix the flaky resize test" --stop "#27310 is merged"` |
| End your task as done, with its PR | `acpmux task done TASK_ID --summary "Fixed the resize lag" --pr https://github.com/manaflow-ai/cmux/pull/27310` |
| End it as blocked or failed, and say why | `acpmux task blocked TASK_ID --summary "Not started" --why "Base is red"` |
| The tasks this chat gave, still running | `acpmux task ls --open` |
| Briefs the daemon tracks | `acpmux briefs ls` |
| Steer the session working a brief | `acpmux briefs steer BRIEF_ID "Rebase first"` |
| Link a session to the tracker beads it works on | `acpmux bead link fix-27310 cx-cus7j` |
| Continue a session's work on another harness | `acpmux continue review-27310 --to codex` |

## Background processes and worktrees

| Task | Command |
| --- | --- |
| Background processes agents left running | `acpmux process list` |
| Follow one's output (Claude Code sessions) | `acpmux process show coord/b7x2k1q --follow` |
| Stop a dev server an agent left running | `acpmux process kill coord/b7x2k1q` |
| Move a Claude Code chat's running commands to the background | `acpmux process background coord` |
| Worktrees a cleanup would touch | `acpmux worktree list` |
| What a cleanup would do, without doing it | `acpmux worktree clean --dry-run` |
| Remove one agent's worktree and the branch cmux made for it, now | `acpmux worktree remove fix-27310` |
| The same, losing its uncommitted or unpushed work | `acpmux worktree remove fix-27310 --discard` |
| Bring back a cleaned-up worktree | `acpmux worktree restore lane/fix-27310` |
| Reclaimed worktrees, newest first | `acpmux worktree archives` |

A cleanup archives work that exists only in a worktree before removing it.

`worktree remove` takes the worktree's folder, a session's name or a worktree's name
(`~/.cmux/worktrees/<project>/<name>`). It refuses, changing nothing, while a running session
works there (`acpmux session stop NAME` first) and while the worktree has uncommitted changes or
commits on no other branch or remote; the refusal names `--discard`. It removes the branch when
cmux made it (`acpmux new --worktree [--branch]`, `cmux workspace create --worktree`), never a
branch that was there before, and the project folder once its last worktree is gone. The app's
`cmux git worktree remove` follows the same rules (`cmux_git::worktree`).

Paths: a worktree prints as `~/.cmux/worktrees/<project>/<name>` (on macOS a link to
`~/.cmux/worktrees.noindex`); `--only`, `worktree remove` and `chats list --folder` take either
spelling, and `/tmp/x` or `/private/tmp/x`, as the same folder. Other folders print as you gave
them: `worktree remove /tmp/x/wt --json` prints `root` and `mainRoot` under `/tmp/x`, not
`/private/tmp/x`.

## Chats, messages and rules

| Task | Command |
| --- | --- |
| Every chat on this device, from every harness | `acpmux chats list` |
| Open one again | `acpmux chats open claude-code:5f0c2a9e` |
| From an agent session, leave a person a report without waking anyone | `acpmux deliver --target reports:PERSON "PR 27310 landed"` |
| Team messages the hub holds | `acpmux inbox` |
| From an agent session, post a rule every session reads at its next prompt | `acpmux forum announce --key builds "No local builds"` |
| The current rules | `acpmux forum rules` |
| From a coordinator session, be woken once when a worker is done or blocked | `acpmux watch add review-27310 my-linux/fix-27311 --match BLOCKER` |
| Watches and the wakes they still owe | `acpmux watch ls` |
| Remove a watch (wakes it already owes still arrive) | `acpmux watch rm WATCH_ID` |

## This machine as a Cloud Chief's hand

| Task | Command |
| --- | --- |
| Pair it | `acpmux hand pair CODE --api https://cloud-api.cmux.dev` |
| Serve Cloud requests in the foreground | `acpmux hand run` |
| Its id, API and roots | `acpmux hand status` |

See also [sessions](cli-sessions.md).
