# Push matrix: terminal agent questions

Rows for terminal-hosted agent questions (`rich-push-termq`). This section merges
into `verify/push-matrix.md`, which the verification lane owns.

## How Claude Code's AskUserQuestion screen takes keys (Claude Code 2.1.308)

Read live on `mini-cmux11s-mac-mini` in a headless tmux (no GUI, no simulator),
with `claude --model haiku` asking the questions below. The mapper
(`TerminalQuestionKeys`) is built from these observations:

| Screen | Keys | Seen |
| --- | --- | --- |
| Two questions: Branch (one choice: main, dev, release), Checks (multi: lint, tests, docs) | `2`, then `1`, `3`, Tab, then `1` on "Review your answers" | Claude got "Which branch? → dev", "Which checks? → lint, docs" and replied "dev, lint, docs" |
| One question, one choice (red, green, blue), Other | `4`, then the text `teal please`, Return | no review screen; Claude got "Pick a color? → teal please" |
| One question, multi (apple, pear, plum), with Other | `2`, `4` (checks Other), Down ×3 to Other, `kiwi`, Down to Submit, Return, then `1` on the review | Review showed "Which fruits? → pear, kiwi" |

## Rows

| Kind | App state | Action | Delivery | Result | Evidence |
| --- | --- | --- | --- | --- | --- |
| Terminal question, 3 options | n/a | Feed card shows question and options, Open in Terminal secondary | daemon `list-notifications` | Pass (unit) | `TerminalQuestionFeedTests.theQuestionShowsInlineWithItsOptions` |
| Terminal question, 3 options | foreground | Answer from the Feed card (tap "dev") | tunnel (`send`) | Pass (live 2026-10-23): Claude Code 2.1.309 got "Which branch should I use? → dev" and replied "GOT dev"; the card then reads "You answered · Branch · dev" | `push-matrix/evidence/termq/termq-feed-single-chosen.jpg`, `termq-feed-single.mp4` |
| Terminal question | n/a | Screen moved on: nothing typed | tunnel | Pass (unit) | `anAnswerTypesItsKeysWhileTheTerminalShowsTheQuestion` |
| Terminal question + multiSelect | background | Long-press view of the real push: radio rows for Branch, checkboxes for Checks, Submit, Face ID | tunnel | Pass (live, after fixes 1 and 2): Claude got "Which branch next? → release", "Which checks should run? → lint, docs" | `termq-push-multi-longlook.jpg`, `termq-push-multi-checked.jpg`, `termq-push-multi-answered.jpg`, `termq-push-multi.mp4` |
| Terminal question | not running | Open from the notification ("Answer…") | n/a | Pass (live, after fix 3): the app cold-launched on the rig Mac's terminal tab (`termq-work`, Claude Code's screen) | `termq-tap-cold-opened.jpg`, `termq-tap-cold.mp4` |
| Push kind for a terminal question | n/a | Mac host pushes `question` with options and `tabId` | Mac host | Pass (unit) | `notify_terminal::a_terminal_agent_question_pushes_as_a_question` |
| Daemon carries the question, memory only | n/a | notification event and ledger row; forgotten once working | daemon | Pass (integration) | `an_agent_question_reaches_the_notification_and_its_row_in_memory_only` |

Pruned: Codex terminal questions (its TUI screen is not mapped; the card shows the
question and refuses an inline answer with "Answer this one in the terminal").

## Live run (2026-10-23)

Rig on `mini-cmux11s-mac-mini` (Claude Code is signed in there only): a hidden rig Mac,
fleet build `31f1b3363990fbfa807a663f` of PR A `9f7dfb976e3c` (tag
`mobile-e2e-termq2`), and one simulator `termq-phone` with the app and content extension
built from the same head plus fix 3. `claude --model haiku` ran in a rig terminal through
the rig app's own `cmux-tui agent claude-wrapper`, so its hooks were this build's. Every
push was the payload the real Mac host posted (`notify-tap.mjs`), turned into the APNs body
by the Worker's own code (`apns-from-capture.ts`), then `xcrun simctl push`. Run script:
`push-matrix/termq_run.py`.

Failures found and fixed:

1. **The question push lost its options.** Claude Code reports its own "asks a
   question" status (an OSC the terminal posts) a moment before its hook's
   notification. The Mac host dropped the hook's notification, which carries the
   question, as that OSC's echo, so the phone got only "claude-code asks a question".
   A question is now never an echo (`notify_terminal.rs`, test
   `a_question_after_the_terminals_own_alert_still_pushes`, red then green on rbx).
2. **Rig only.** The rig's Claude ran with the previous build's hook helper (an older
   rig app was still in the rig folder), so no hook reached this build's daemon. The
   rig now holds one app.
3. **The tap opened an empty agent chat.** A terminal agent's question has no acpmux
   session; the route matched the terminal's tab id to a chat. A notification with no
   session that names a terminal tab now opens that terminal
   (`NotificationRouteTests.aTerminalAgentsQuestionOpensItsTerminal`, red then green
   on mini-cmux7s).

Not run and why:

- A tap on the banner body: AXe's touches do not reach SpringBoard's notification cell
  on this simulator; the cold launch was opened from the same notification's
  "Answer…" action, which opens the app on the same route.
- The phone pinned to this rig's Mac through the Mac filter, because another agent's
  rig Mac runs on the same mini and account: Macs on one computer are listed once
  (`MacRoster`, #24167), so the phone focuses one of them. A notification still opens
  and answers on its own Mac (`touch`).

Follow-up (not fixed here): each terminal AskUserQuestion also leaves the hook's
generic "Asked a question: AskUserQuestion / Answered in the terminal" rows in the
Feed next to the rich card (two per question: PreToolUse and PermissionRequest).

## Rerun on the final head (2026-10-23, `e2349efc8527`, rig `mobile-e2e-termq5`)

| Row | Result | Evidence |
| --- | --- | --- |
| One AskUserQuestion with two questions | Pass: exactly one push, `q-90ae2c71d0aa2143` (the Mac's key, recomputed from the daemon's row on the phone side to the same value) | `notify-capture.jsonl` |
| Long look: Branch "release", Checks "lint" and "docs", Submit, Face ID | Pass: Claude Code got `Which branch next?="release", Which checks should run?="lint, docs"` | `push-matrix/evidence/termq/termq5-longlook.jpg`, `termq5-checked.jpg`, `termq5-answered.jpg`, `termq5-push-multi.mp4` |
| The same old notification answered while a newer question waits on that tab | Pass: nothing typed (the terminal still shows the new question); the phone says "Not sent to Rig Mac: This was already answered." | `termq5-stale-refused.jpg` |

Failures found and fixed in this round:

4. **One question pushed twice, and the answer then missed.** Claude Code 2.1.309 posts
   PreToolUse and PermissionRequest for one AskUserQuestion in either order, and
   PermissionRequest carries no `tool_use_id`. A push named by the tool use came out as
   `q-<tool>` plus `n-3`, or only `n-2` when the order flipped. The push is now named by
   an FNV-1a hash of the question's prompts and option labels on both the Mac and the
   phone (shared vector `q-c2e23c8e74d254a9`), deduped per tab for 30 s
   (`notify_terminal` tests on rbx; `TerminalQuestionFeedTests` on mini-cmux7s).
5. **Rig only.** A new rig build is a new Mac device: the phone must be pinned to it
   (`PUSHPHONE_LAUNCH_ARGS`) and its link id seeded for pairing.
