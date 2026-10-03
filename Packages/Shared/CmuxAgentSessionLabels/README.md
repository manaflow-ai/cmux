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
whole listing. `unreadableRecords` names the rows that were skipped, including a
record filed under a key that no write could address, such as `"codex "`.

A rewrite keeps what it does not understand: fields inside a record, records it
could not read, and top-level keys another program added all come back out as
they went in. Only the `label` and `updated_at` of the record being written
change.

## What the lock does not cover

- The sidecar sits next to the file a write resolves to, not next to the path the
  store was given. Two state directories that symlink to one document therefore
  share one lock, which is the point; two symlinks to one document from different
  names do too.
- On a case-insensitive volume, two paths differing only in case are one file but
  give two sidecars, so two writers would not see each other. cmux builds the
  path from a fixed file name, so this needs a caller that passes its own.
- `flock` is per-host and is advisory on some network file systems. A state
  directory on NFS or SMB shared between two machines is not serialized by this.
  cmux state is local.

Tests run on Linux (`swift test` in this directory); the package is
Foundation-only for that reason.
