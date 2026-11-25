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

## 1. One workspace per task, no duplicates

- Title: `<issue#>: <3-5 word liner>`, the number of the issue or pull
  request the work is for and what it does, for example
  `4812: Flaky login test`. Without a number: 3-5 words of what it does.
  Never `fix`, `task 3`, `#NEXT` or another placeholder.
- Look first: `cmux --json workspace list`. A workspace whose name starts
  with that number, or names that same work, already has its agent: send
  the new words there (`cmux agents chat send <chat> -- "<text>"`), move it
  to the top (`cmux workspace <ws_…> move --index 0`) and say so. Never
  start a second agent on the same issue.

## 2. Start the chat

```sh
cmux --json agents chat new --top --harness claude --cwd <repo> \
  --name "<title>" -- "<prompt>"
```

- `--harness claude` for Claude, `--harness codex` for Codex. Leave out
  `--model` and `--effort`: the harness's default model and effort run, as
  in the app's New Agent Chat. Pass them only when the person names a
  model or an effort.
- `--top` makes a new workspace first in the sidebar, under Home, holding
  only the chat: add no terminal to it.
- `--cwd` is the repository or folder the work is in, never `~`.
- The receipt names the chat (an acpmux session id), its tab, pane and
  workspace. When the workspace's name is not the title, `cmux workspace
  <ws_…> rename "<title>"`.
- Several tasks: one `agents chat new` per task, each with its own title.

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
you cannot verify.
```

## 4. Check before you say sent

`cmux --json agents chat state <chat>` must show it running (or its first
turn started). Then post one line per agent: the title and a link to its
workspace, `[4812: Flaky login test](cmux://workspace/ws_…)`. A start that
failed: read the receipt or the chat (`cmux agents chat read <chat>`), fix
the cause and start it again in the same workspace; never leave a failed or
empty workspace behind, and never report a chat you did not see running.

## 5. Follow it to the end

- When its pull request is ready, tell the person in one line what it does
  and link it: `[OWNER/REPO#123](https://github.com/OWNER/REPO/pull/123),
  which makes new windows open with one workspace`.
- When its pull request merges, close the workspace you made for it
  (`cmux workspace <ws_…> close`) and say so in one line.
- Nudging an agent later: `cmux agents chat send <chat> -- "<text>"`, then
  `cmux agents chat state <chat>` to see that it took the message.
