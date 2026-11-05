---
name: cmux-chat
description: "How a cmux chat shows your work: the plan list it draws, side sessions and offered sessions, links to other sessions, the closing recap, and editing cmux itself live. Read it at the start of a task with more than one step, before starting or suggesting another session, and before ending a turn that changed files."
---

# Working in a cmux chat

cmux NEXT draws your chat as a pane: your plan as a checklist, your sub-sessions in a
tray under the chat, session links as chips, offers as cards. These rules say when to
use each. They are cmux's defaults; the person's own instructions win.

## Plan list

Use it when the task has more than one step (edits plus a test, an investigation then a
fix, anything the person listed). Skip it for a one-command answer or plain talk.

- Claude Code: `TodoWrite`. Codex: `update_plan`. Other agents: their plan tool.
  cmux draws the newest list as a checklist and keeps earlier lists as history.
- Write the whole plan in the first tool step, short imperative items (at most about
  7 words), one item in progress, the rest pending.
- Mark an item done when it is done, in the same step that starts the next one.
  Rewrite the whole list when the plan changes, so it never shows abandoned work.
- Never also write the plan as a numbered list in your reply: the checklist is the plan.

## Side sessions, sub-sessions and subagents

A sub-session is a new agent chat the person can open, steer and stop. Use one only for
work with its own result (a branch, a PR, a separate investigation) that can run while
you go on, never for a step you need the answer to right now: do that yourself or in your
harness's own subagent (Claude Code's Task/Agent tool), whose result comes back to you.

- `start_session` (server `cmux-subsessions`): starts a child now. Use it when the person
  asked for parallel or background work. Pass `worktree: true` when it edits files that
  yours may also touch. Its prompt carries the whole task: it starts with none of your
  context. Read results with `wait_for_sessions` or `get_session`; steer with
  `send_message`.
- `offer_session` (server `cmux-sessions`): one suggestion mid-turn for work you noticed
  outside the task (a bug, a cleanup). The person starts it or not; do not do that work here.
- `suggest_tasks` (server `cmux-sessions`): at the end of a turn, up to 5 follow-ups the
  person may want, drawn as one card.
- Not for: quick lookups, a handful of tool calls, or pieces of one change. Never start a
  session the person did not ask for; offer it instead.
- To show a session's chat, `app_agent_open` (server `cmux`) with its sessionId.

## Linking sessions

When you mention another session (one you started, one that messaged you, one in a PR
footer), write a reference cmux turns into a clickable chip, in inline code:

- its `HOST/NAME`, as `list_sessions` or `acpmux ls` shows it (`huge-blue/tests`), or
- its agent link: `cmux://agent/<harness>/<sessionId>` or the
  `https://cmux.com/deeplink/agent?...` link a PR footer carries.

Never invent an id. A name you only guessed stays plain text.

## Closing recap

End every turn that changed files, ran commands or finished multi-step work with a
short recap, the last thing you write:

- what is now true or changed, in two or three sentences;
- what you verified and how, and what is not done or not verified;
- the one decision the person must make next, if any, as a single question.

Skip it for a short answer or plain conversation. Do not restate the plan or the diff.

## Editing cmux live

When the person asks to change how cmux itself looks or behaves (a panel, a view, a
setting) and the `cmux-live` skill is listed, read it first: it edits the running app
and reloads it in place. For settings and a person's own views, use `cmux-customization`.

## The person's own skills

The person can add skills in `~/.config/cmux/skills/<name>/SKILL.md`. Claude Code lists
them as `cmux-user:<name>`; other agents get their names, descriptions and paths in the
chat's first message. Read one when its description matches the task.
