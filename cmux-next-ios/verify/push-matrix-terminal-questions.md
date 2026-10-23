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
| Terminal question, 3 options | n/a | Answer from the Feed card | tunnel (`send`) | Pass (unit, fake daemon); live run pending | `anAnswerTypesItsKeysWhileTheTerminalShowsTheQuestion` |
| Terminal question | n/a | Screen moved on: nothing typed | tunnel | Pass (unit) | same test |
| Terminal question + multiSelect | foreground | Answer from the notification (long-press rows, Submit) | tunnel | Pending live run on the rig | |
| Terminal question | not running | Tap opens the terminal tab | n/a | Pending live run on the rig | |
| Push kind for a terminal question | n/a | Mac host pushes `question` with options and `tabId` | Mac host | Pass (unit) | `notify_terminal::a_terminal_agent_question_pushes_as_a_question` |
| Daemon carries the question, memory only | n/a | notification event and ledger row; forgotten once working | daemon | Pass (integration) | `an_agent_question_reaches_the_notification_and_its_row_in_memory_only` |

Pruned: Codex terminal questions (its TUI screen is not mapped; the card shows the
question and refuses an inline answer with "Answer this one in the terminal").
