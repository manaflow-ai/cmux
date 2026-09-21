# Workspace presence

One `WorkspacePresenceSession` belongs to one mounted workspace view. The view
runs `run(scope:accessToken:isCurrent:)` in a cancellable task and reports active
viewing with `setViewing`. Its auth closure captures an account/team generation;
a later account switch cannot lend credentials to an older workspace session.

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
