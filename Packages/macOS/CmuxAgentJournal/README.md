# CmuxAgentJournal

Journal-backed sidebar agent lifecycle: an append-only, replayable log of
semantic agent events, plus the deterministic reducer that derives
Running / NeedsInput / Idle / Error for the sidebar from it.

The design is a Swift port of the cmux-tui session journal
(`cmux-tui/crates/cmux-tui-core/`): the same process and turn `agent.*` semantic kinds, plus a separate
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
- `AgentGoalLifecycle` — provider-neutral objective state, generation, timestamp,
  and provenance. Goal events are stored in a durable projection separate from
  process lifecycle, so `running` plus `complete` is a valid session view.

## Objective hook

Providers that expose an authoritative objective receipt can publish it through
the exact-session command below. The command requires workspace and surface UUIDs
and accepts explicit retry inputs. A retry must reuse both the original
`--updated-at-ms` and `--event-id` values so it replays the same journal receipt:

```sh
cmux agent goal-state complete \
  --agent codex --session <thread-id> --generation <goal-id> \
  --workspace <workspace-uuid> --surface <surface-uuid> \
  --provenance provider_hook --updated-at-ms <timestamp> --event-id <event-id>
```

Codex app-server `ThreadGoalUpdatedNotification` values map directly to
`active`, `paused`, `blocked`, or `complete`; `usageLimited` and `budgetLimited`
are reported as `blocked` by the producer. Providers without an authoritative
objective report `unmanaged`, while an unavailable receipt reports `unknown`.
The command never accepts prompts, transcripts, credentials, or objective text.
Use `--previous-generation` when replacing a completed generation. The journal
rejects a replacement unless it names the currently stored generation, which
prevents a late completion from an earlier objective from changing the new one.

Each newly committed goal update also emits `agent.goal.state_changed` on the
public `cmux events` stream. Its payload contains the event id, exact provider
session id, lifecycle state, generation, producer timestamp, and provenance;
the journal event id and stream sequence make reconnect and deduplication safe.
Replaying an already committed append does not emit a second public event.

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
