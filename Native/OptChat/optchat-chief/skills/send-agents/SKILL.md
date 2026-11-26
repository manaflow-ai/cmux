---
name: send-agents
description: Send Claude or Codex on a task as an agent chat in the cmux app, each in its own workspace at the top of the sidebar, and follow it until its pull request lands. Use when the person says "send Claude", "send Codex", "start Claude on X" or "an agent for each of these", and when an agent's pull request merges.
cmux-managed: true
---

# Sending agents

"Send Claude on X" means a new agent chat the person sees in the cmux app,
one per task, that does the work and opens a pull request. Do it yourself,
now, one chat per task: never a subagent whose job is to start agents,
never a terminal (unless the person says terminal), never a message to a
chat that is already open on something else.

## 1. An issue first, one workspace per issue

- Work in a GitHub repository with no issue yet: file one first (`gh issue
  create`), a short sanitized summary of the task in your own words, never
  the person's raw prompt or a secret.
- Title: exactly `<issue#>: <3-5 word liner>`, the issue number (never the
  pull request's, never a `#`) and what the work does, for example
  `4812: Flaky login test`. Work that has only a pull request:
  `PR #<number>: <3-5 words>`; with neither, 3-5 words of what it does.
  Never `fix`, `fix issue N`, `task 3`, `#NEXT` or another placeholder.
- Look first: `cmux --json workspace list`. A workspace whose name starts
  with that number, or names that same work, already has its agent: send
  the new words there (`cmux agents chat send <chat> -- "<text>"`), move it
  to the top (`cmux workspace <ws_…> move --index 0`) and say so. Never
  start a second agent on the same issue.

## 2. Start the chat

```sh
cmux --json agents chat new --top --harness claude --model claude-opus-5-5 \
  --effort medium --cwd <repo> --name "<title>" -- "<prompt>"
```

- Claude runs on Opus 5.5 at medium effort, as above. Codex: `--harness
  codex` with its default model and effort. A model or effort the person
  names wins.
- `--top` makes a new workspace first in the sidebar, under Home, holding
  only the chat. Never `cmux workspace create` first (it adds a terminal),
  and add no terminal to it.
- `--cwd` is the repository or folder the work is in, never `~`.
- The receipt names the chat (an acpmux session id), its tab, pane and
  workspace. When the workspace's name is not the title, `cmux workspace
  <ws_…> rename "<title>"`.
- Several tasks: one `agents chat new` per task, each with its own title.
  Do it yourself: no helper chat, subagent or workspace to start them.

## 3. The prompt

The person's own words for the task first, then these lines (they are the
standing rules for every agent you send; add the person's own rules that
apply, in their words):

```
Do the work yourself: never start other agent chats or workspaces; use
in-process subagents only if you need them.
Make a complete fix, not only an investigation. Verify it yourself as far
as you can (tests, a dev build) before you call it done.
Open a pull request when it works, and open it in a browser in the right
split of your own workspace: `cmux identify --json` gives your pane
(.caller.pane); split it with `cmux --json pane <pane_…> split --right
--ratio 0.5` and `cmux browser open <PR URL> --pane <new pane_…>`. Never
use the `current` or `focused` selectors and never pass --focus.
Keep going until the pull request is ready: checks your change broke are
fixed, review comments answered, no merge conflicts. Then stop.
If you launch a dev build, quit it once you are done verifying it, or when
you cannot verify. Never move the person's focus.
```

## 4. Check before you say sent

`cmux --json agents chat state <chat>` must show it running (or its first
turn started). Then post one line per agent: the title and a link to its
workspace, `[4812: Flaky login test](cmux://workspace/ws_…)`. A start that
failed: read the receipt or the chat (`cmux agents chat read <chat>`), fix
the cause and start it again in the same workspace, unasked; never leave a
failed or empty workspace behind, and never report a chat you did not see
running.

## 5. Follow it to the end

- An agent's diagnosis or "it works" is a claim: check it against real data
  (the diff, the logs, a test run) before you pass it on, and say what you
  verified.
- When its pull request is ready, tell the person in one line what it does
  and link it: `[OWNER/REPO#123](https://github.com/OWNER/REPO/pull/123),
  which makes new windows open with one workspace`.
- A ready pull request to `feat-cmux-next` whose change was verified (tests
  or a dev build) and has no conflicts: squash-merge it (`gh pr merge <n>
  --squash`). Pull requests to any other branch wait for the person.
- When its pull request merges, close the workspace you made for it
  (`cmux workspace <ws_…> close`) and say so in one line.
- Nudging an agent later: `cmux agents chat send <chat> -- "<text>"`, then
  `cmux agents chat state <chat>` to see that it took the message, and move
  its workspace to the top.
