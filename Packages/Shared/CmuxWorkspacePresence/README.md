# Workspace presence

One `WorkspacePresenceSession` belongs to one mounted workspace view. The view
runs `run(scope:accessToken:isCurrent:)` in a cancellable task and reports active
viewing with `setViewing`. Its auth closure captures an account/team generation;
a later account switch cannot lend credentials to an older workspace session.

`WorkspacePresenceRoster` shares sessions for the set of visible sidebar rooms
and the selected workspace. Observing a row is passive: only the foreground
selection calls `setViewing(true)`. Rows read immutable collaborator lists by
canonical scope; account/team replacement clears every list before reconnecting.
The `changes()` stream names the rows whose lists changed, including disconnects.
An invisible row releases its session unless it is still the active workspace.

The transport talks to `/v1/workspace-presence`. Every frame is a full, bounded
snapshot scoped to one workspace. A connection starts passive, renews active
viewing every 15 seconds, and expires after 45 seconds without renewal. The
model clears participants on close, decode failure, scope mismatch, or teardown.
The Worker never changes terminal access or device reachability.

Tests inject `WorkspacePresenceConnecting` and a `Clock<Duration>`; no AppKit,
user defaults, network account, or application launch is needed. For example:

```swift
let model = WorkspacePresenceSession(transport: fixture, clock: clock)
model.setViewing(true)
let task = Task { await model.run(scope: scope, accessToken: { "fixture" }, isCurrent: { true }) }
// Send a snapshot through the fixture, then cancel the view's task.
task.cancel()
```
