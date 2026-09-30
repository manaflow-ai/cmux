# Agent session labels

`AgentSessionLabelStore` holds the cmux-authored display name of one agent
session, keyed by the agent and the session id. Agent sessions come from each
agent's own files, and none of those records carries a name cmux may write: the
hook-session payloads have no title field, and hooks rewrite them. A label is the
cmux-owned side of that, which is why it is validated on the way in.

The document lives at `<state dir>/agent-session-labels.json`, version 1, with
labels sorted by agent and session id so a change reads as one line of a diff.

```swift
let store = AgentSessionLabelStore.inStateDirectory(stateDirectory)
let key = try AgentSessionLabelKey(agent: "codex", sessionID: "s-1")
try await store.setLabel("auditing the socket rows", for: key)
let snapshot = try await store.snapshot()
```

Both the CLI (`cmux sessions label`) and the macOS app write this file, so every
write takes an exclusive `flock` on a sidecar next to it. Actor isolation alone
would not serialize two processes.

`snapshot()` reports a record it could not read rather than throwing, because
every agent's labels share one document and one bad row would otherwise blank a
whole listing. `unreadableRecords` names the rows that were skipped.

Tests run on Linux (`swift test` in this directory); the package is
Foundation-only for that reason.
