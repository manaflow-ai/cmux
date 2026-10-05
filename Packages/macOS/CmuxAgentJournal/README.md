# CmuxAgentJournal

Journal-backed sidebar agent lifecycle: an append-only, replayable log of
semantic agent events, plus the deterministic reducer that derives
Running / NeedsInput / Idle / Error for the sidebar from it.

The design is a Swift port of the cmux-tui session journal
(`cmux-tui/crates/cmux-tui-core/`): the same 12 `agent.*` semantic kinds, the
same normalized-key native-event mapping, an append-only SQLite table with a
monotonic sequence and immutability triggers, and idempotent appends keyed by
event id so producer retries replay the original receipt.

## Pieces

- `AgentJournalEventKind` — the 12 semantic `agent.*` kinds.
- `AgentSemanticEventMapper` — native hook event name → semantic kind
  (normalized-key matching; per-source special cases for antigravity,
  hermes-agent, opencode, and the copilot/codebuddy/factory trio).
- `AgentJournalEventDraft` / `AgentJournalEvent` — the wire draft (the
  `agent_journal_append` socket verb payload) and the committed record.
- `AgentJournalStore` — append-only SQLite store with durable append
  receipts, sequence-ordered reads, restore-time identity alias tables, and
  bounded open-time retention.
- `AgentLifecycleReducer` / `AgentLifecycleReducerState` — the deterministic
  fold: per-session newest-event-wins (drop duplicates and stale
  out-of-order arrivals), surface phase = precedence combine over live
  sessions. Unattributed events become bounded diagnostics, never guessed
  state.
- `AgentLifecycleSnapshot` / `AgentLifecycleAssignment` — the combined view
  and the diff the app applies to `Workspace.setAgentLifecycle`.
- `AgentJournalReplayPolicy` — what a relaunch may repaint from history
  (needsInput/error survive; running/idle/unknown wait for live evidence).

## Testing

Everything is constructor-injected and runs headless:

```swift
let store = try AgentJournalStore(databaseURL: temporaryURL)
let outcome = try store.append(draft)          // durable receipt
var state = AgentLifecycleReducerState()
let reducer = AgentLifecycleReducer()
for event in try store.events(afterSequence: 0, limit: 1024) {
    reducer.apply(event, to: &state)
}
let assignments = state.snapshot().assignments(since: previousSnapshot)
```

`swift test --package-path Packages/macOS/CmuxAgentJournal`

## Per-session activity and mode

`state.sessions[surfaceID]?[toolID]?[sessionID]` retains rich activity independently
for every native session. The legacy combined phase remains available for older
consumers; it must not replace these separate observations in API 2.2.

Native schema-1 producers may add `declared_activity`, `declared_reason`,
`declared_mode`, and `process_generation`. Activity and mode have separate
sequence watermarks. A mode-only `plan` event leaves activity unknown; an explicit
`agent.plan_review.requested` creates needs-input with the plan-review reason.
`build` mode normalizes to `execution`. Activity is never inferred from prose.

Original event, transition, and mode timestamps are preserved. A current process
sample is separate evidence and never refreshes those times. Native projection
requires a registered session/tool identity and a current process birth; replay
from an older process generation cannot establish current activity or mode.
The generation is process start seconds × 1,000,000 + start microseconds.

Exact question/permission replies and rejections retire their request identity.
A later coarse busy observation cannot hide an unresolved request, and a late
replay of an already resolved question cannot reopen it.
