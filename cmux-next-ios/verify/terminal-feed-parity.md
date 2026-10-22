# Terminal agents in the Feed: parity with GUI chats

Branch `feat-cmux-next-terminal-agent-feed`, PR #24205, 2026-10-22.

User direction: "terminal agents must also reach the Feed entirely, not just GUI." An agent started by typing its command in a cmux terminal tab (Claude Code, Codex, opencode, Gemini CLI) should give the same Feed card a GUI agent chat (an acpmux session) gives.

Ownership:
- The rich-push lane (`feat-cmux-next-ios-rich-push`, `-push-fallback`, `rich-push-termq`) owns questions and permissions: structured AskUserQuestion content, inline answers, and push.
- This lane owns the rest: prompt, answer, tool and error text, finished state, and the free-text reply.
- Both lanes use one event model. The daemon's `notification` event carries `id`, `prompt` and `message` (this lane). rich-push-termq adds `question` beside them.

## 1. Where each one comes from

| | GUI chat (acpmux session) | Terminal agent (before this branch) |
| --- | --- | --- |
| Source | `LiveFeed` reads acpmux `_acpmux/watch` (`session_changed`, `permission_pending`) over the `acpmux` channel | `TerminalFeed` reads the daemon's notification ledger (`list-notifications`) over the `daemon` channel. It reads again on each `notification` event or marker change |
| Producer on the Mac | acpmux session records: `lastPrompt`, `preview` (200 characters, `hub/watch.rs:210`), `lastTurn` | The hook helper `cmux-tui-hook <provider> <event>` sends `session.journal.append`. Then `agent_hook_notification` writes a ledger row with title "\<Agent\> finished / needs approval / asked a question / reported an error" and body = `tool_name` only |
| Hooks installed | n/a | Claude: SessionStart, UserPromptSubmit, Stop, StopFailure, Notification, PermissionRequest, Pre/PostToolUse, PostToolUseFailure, SubagentStart/Stop, and others (`cmux-tui-hooks` `CLAUDE_EVENTS`). Codex: SessionStart, UserPromptSubmit, Stop, PermissionRequest, Pre/PostToolUse, Pre/PostCompact, SubagentStart/Stop, SessionEnd (`CODEX_EVENTS`). Only 5 kinds post a ledger row: turn completed, approval, question, plan review, error |
| Push | `cmux-mobile-host` `notify.rs` (acpmux watch), with the #23803 dedupe (compactor and sub-sessions filtered, 30 s coalescing) | none (the rich-push lane adds it) |

## 2. Gap inventory: each Feed field, GUI vs terminal

"Before" is origin/feat-cmux-next at 04196dafb8d9. "After" is this branch.

| Feed field | GUI chat card | Terminal, before | Terminal, after |
| --- | --- | --- | --- |
| Your prompt (quote bubble) | `lastPrompt` | None. The hook read `prompt` (UserPromptSubmit), but only the hover card got it (200 characters, `list-agents last_prompt`). The Feed never read it | The `notification` event's `prompt` (the whole prompt, up to 4000 characters, memory only) becomes the quote bubble |
| Assistant answer (markdown) | `preview` (200 characters) | "Finished its turn in the terminal. Open it to see the result." The hook read `last_assistant_message`, but only into the banner's 200-character `preview`, and the phone dropped the event's fields (`DaemonTree.swift:390`) | The event's `message`: the whole answer, markdown and line breaks kept, up to 4000 characters. Kind `response`, as a chat's |
| Tool calls (command, output) | Not in the Feed card. Only in the chat transcript (`AgentSessionEvent`) | Not shown. `tool_input` is redacted before the journal, and only the tool name reaches the row body | Unchanged (the GUI Feed shows none either). An error card names the failed tool and shows its error text |
| Permission (full command, Allow / Always / Deny) | `ACPPermissionRequest` card, Allow once / Deny (the phone gets no lasting grant) | `.needsInput`, "Needs approval: Bash", Answer in Terminal | Unchanged here. The rich-push lane owns it. This branch adds the prompt quote |
| Question with options | `QuestionCard` (`AgentQuestion`) | `.needsInput`, "Asked a question.", Answer in Terminal | Unchanged here. The rich-push lane owns it (`question` on the event, rich-push-termq) |
| Finished, with summary | `.response` with the preview | `.finished`, generic sentence | `.response` with the whole answer |
| Error, with message | `.failed`, the turn's `errorText` | `.failed`, "**Reported an error:** Bash" | Same headline, plus the error text in a code block (Claude `PostToolUseFailure`/`StopFailure` `error`) |
| Diffs, changed files | Not in the Feed card (chat transcript only) | none | Unchanged (no GUI Feed equivalent). Recorded as a gap for both |
| Model and agent | Agent name and avatar. No model in the Feed card | Agent from the harness (`Codex`, `Claude`) | Same |
| Workspace, Mac, timestamps | Workspace title, `macID`, `createdAt` | Same (`TerminalFeed.item`) | Same |
| Thread grouping | None. Each item stands alone | None | None |
| Reply to a finished turn | Reply sends `session/prompt` into the chat | No Reply button (`FeedCell` footer hid it for `opensTerminal`) | Reply types into that terminal's agent and submits (section 3). The card shows "Typing into the terminal…", then "Sent to the terminal" or the reason it wasn't sent |
| Answers to asks | Inline, Face ID signed | Open the terminal | Unchanged here (rich-push lane) |
| Sub-agents, compactor | Filtered in push (#23803) | Sub-agent hooks (`agent.child.*`) post no ledger row | Unchanged. No new row kinds, so nothing new to filter. The #23803 dedupe and push kinds are untouched |

## 3. The changes

Mac daemon (cmux-tui):
- `agent_hooks.rs`: `live_prompt` and `live_reply` keep whole markdown text (`live_message_text`, up to `LIVE_MESSAGE_CHARS` = 4000). Line breaks and tabs stay. Other control characters and invisible format characters are dropped.
  - For `agent.error.reported` the reply is the error text (`error`, `error.message`, `error_message`, `reason`).
- `agent_prompts.rs`, `feed_local.rs`, `notification_types.rs`, `cmd_subscribe.rs`: the `notification` event gains `id`, `message` and `prompt`.
  - `preview` stays the banner's folded 200-character cut, and `list-agents last_prompt` stays the hover card's.
  - Memory only, as before: nothing new in the ledger, the journal or any daemon file.
- Tests (behavior, `terminal_host_recovery::command_activity`, which run the real hook helper against a real daemon):
  - `a_finished_turn_notification_carries_the_whole_prompt_and_answer_for_the_feed`: whole prompt and answer, the ledger id joins, and nothing on disk after a checkpoint.
  - `an_error_notification_carries_the_error_text_for_the_feed`.
  - Both fail at the tests-only commit 9f4ee59f4557 and pass at the fix.

Phone (CmuxMobileKit):
- `DaemonTree.swift`: `DaemonEvent.notification(NotificationPost)` carries `id`, `surface`, `source`, `prompt`, `message` and `preview`.
- `TerminalFeed.swift`:
  - Keeps each row's texts by ledger id, in memory, for this Mac.
  - A finished row becomes `.response` with the answer and the prompt as its quote. An error row gets its error text.
  - A later read of the thin ledger row keeps the texts.
  - A Mac without `id` gets its `preview` attached to the next new agent row on that terminal.
- `TerminalFeed.reply(itemID:text:)`, `FeedCell` (Reply on terminal finished and error cards) and `ShellModel` (routes to the item's own Mac).
- Tests: `TerminalFeedTests` (6 new; `CmuxMobileLiveTests`, 248 passed on mini-cmux11s, iOS 26.5 simulator).

Host (`cmux-mobile-host`): no allowlist change. `allows_the_terminal_feed_reply` pins the exact reply lines, and `notification-reply` stays refused.

### Reply rules (security)

Typing into a terminal from the Feed is a remote input path. It is restricted to the paired owner's phone, over that Mac's approved link and the connection the event came on. Within that, it only goes to the waiting session that posted the event:
1. The event is still that terminal's newest.
2. The terminal still runs an agent of the same harness.
3. The agent is at its prompt: not working, not blocked on an approval or question.
4. `process-info`'s foreground program is not a shell.
5. The daemon checks `expect_foreground` again right before each write (paste, then Return).

See `cmux-next-ios/SECURITY.md`, "Terminal agents' texts and the Feed reply to a terminal agent".

## 4. Live comparison over the real link

(Filled in by the live run below.)
