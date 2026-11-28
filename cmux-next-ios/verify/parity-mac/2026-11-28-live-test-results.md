# Live test results under an agent's test command

- Section: Agent chat
- Mac sends: An agent's test command (cargo, nextest, pytest, jest, vitest, bun, go, swift) shows a card under its row whose passed, failed and skipped counts tick as the output streams; each failure names the test with a chip that opens the file at its line.
- Phone: none: the counts and failures ride the tool call as `_meta.acpmux.testResults`, which the phone already receives; whether its chat draws them was not checked.
- State: missing (not checked)
- Notes: The counts are read in the acpmux hub, so every client of a session sees the same numbers.
