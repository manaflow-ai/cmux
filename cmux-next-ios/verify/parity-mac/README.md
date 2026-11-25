# Phone parity rows: one file per row

Every new cmux-next macOS feature also works in the iPhone app, or says why not (cmux `CLAUDE.md`, "macOS and iOS
parity"). Its parity row is a new file here, in the PR that adds the feature.

Why a directory: the single table, [`../parity-mac.md`](../parity-mac.md), took new rows at the top of its
sections, so two open feature PRs conflicted on GitHub (29 of the 107 PRs that edited it in the 14 days to
2026-11-25, 339 base merges carried by them; `scripts/ci/conflict_hotspots.py`). Two new files never conflict.
That table is frozen: its rows stay there and are updated in place (a state going from `missing` to `works`
changes a line), but a PR that adds rows to it fails the fast gates' "entry logs" check
(`scripts/ci/entry_logs.py`).

- Name: `YYYY-MM-DD-<feature-slug>.md`, for example `2026-11-25-find-in-terminal.md`.
- Content: the row's columns, one per line, so a later state change edits one line:

  ```markdown
  # Find in a terminal (Cmd-F; whole history, Match Case, Full Words, Regular Expression)

  - Section: Terminal
  - Mac sends: daemon `terminal-find {surface, query, case_sensitive, whole_word, regex}`
  - Phone: the terminal's Find button
  - State: works
  - Notes: cmux#53152; verified on the simulator (`verify/...`)
  ```

- State is one of the table's: **works** (on the phone and verified), **partial** (on the phone with a stated
  limit), **missing** (not on the phone yet), **not from a phone** (kept off on purpose, with the reason, as
  [`../../SECURITY.md`](../../SECURITY.md) records it).
- To read every row: `cat cmux-next-ios/verify/parity-mac/2*.md`.
