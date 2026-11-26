---
name: cmux-chat
description: "How a cmux chat shows your work: side sessions and offered sessions, links to other sessions, the closing recap, and editing cmux itself live. Load it once per chat, with your first reads, when a task may start or suggest another session, or will change files."
---

# Working in a cmux chat

cmux NEXT draws your chat as a pane: your sub-sessions in a
tray under the chat, session links as chips, offers as cards. These rules say when to
use each. They are cmux's defaults; the person's own instructions win.

## Side sessions, sub-sessions and subagents

These tools exist only when cmux lists them (the person can turn sub-sessions off, and a
chat outside the cmux app shows no offers); skip what you do not have.

A sub-session is a new agent chat the person can open, steer and stop. Use one only for
work with its own result (a branch, a PR, a separate investigation) that can run while
you go on, never for a step you need the answer to right now: do that yourself or in your
harness's own subagent, whose result comes back to you. Fork it by default (Claude Code
Agent with `subagent_type: "fork"`, Codex with inherited turns).

- `start_session` (`cmux.subsessions_start_session` in cmux_exec): starts a child now. Use it when the person
  asked for parallel or background work. Pass `worktree: true` when it edits files that
  yours may also touch. A child normally forks your chat. Give it the assignment and
  expected result. Include the context it needs for a separate worktree or a fresh session. Read results with `wait_for_sessions` or `get_session`; steer with
  `send_message`.
- `offer_session` (`cmux.sessions_offer_session`): one suggestion mid-turn for work you noticed
  outside the task (a bug, a cleanup). The person starts it or not; do not do that work here.
- `suggest_tasks` (`cmux.sessions_suggest_tasks`): at the end of a turn, a few follow-ups
  (usually 2 to 5) the person may want, drawn as one card.
- Not for: quick lookups, a handful of tool calls, or pieces of one change. Never start a
  session the person did not ask for; offer it instead.
- To show a session's chat, `app_agent_open` (server `cmux`) with its sessionId.

## Linking sessions

When you mention another session (one you started, one that messaged you, one in a PR
footer), write a reference cmux turns into a clickable chip, in inline code:

- its `HOST/NAME`, as `list_sessions` or `cmux agent ls` shows it (`huge-blue/tests`), or
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
When the cmux tools list `acpmux_wrap_up`, pass the recap to it (it draws the box under
your answer) instead of also writing it in prose.

## Asking for a connection

When you need the person to connect GitHub (for a repository or an org), call
`settings_ask` (`acpmux_settings_ask` on the cmux server) with `target`
`connection:github`, `connection:github:ORG` or `connection:github:OWNER/REPO` and a
short `why`, then end your turn. The chat shows a small Needs you card with a working
Connect GitHub button under your answer; when they connect, the chat goes on. Never tell
them to open Settings and hunt for it.

For any other setting, call `settings_ask` with `target` `setting:SECTION` or
`setting:SECTION/KEY` (for example `setting:terminal/terminal.fontSize`) and write the
`cmux://settings/...` link it returns in your answer: the chat draws it as a link, and a
click opens that exact setting in Settings.

## Editing cmux live

When the person asks to change how cmux itself looks or behaves (a panel, a view, a
setting) and the `cmux-live` skill is listed, read it first: it edits the running app
and reloads it in place. For settings and a person's own views, use `cmux-customization`.

## The person's own skills

The person can add skills in `~/.config/cmux/skills/<name>/SKILL.md`. Claude Code lists
them as `cmux-user:<name>`; other agents get their names, descriptions and paths in the
chat's first message. Read one when its description matches the task.
