# Rust SDK consumer friction

No raw request or JSON escape hatch was needed. The app uses public generated
models, generated command methods, `SubscriptionBuilder`, and `CmuxStream`.

Prioritized SDK and protocol improvements:

1. Protocol 10 has no agent-change event. A live dashboard must poll
   `list-agents`, adding latency and load even while its delta subscription is
   healthy. A typed agent lifecycle event is the highest-value improvement.
2. The race-free bootstrap sequence is manual: open a delta subscription,
   retain pre-ack events, fetch `list-workspaces` and `list-agents`, apply the
   snapshots, then drain buffered events. A `subscribe_with_snapshot` helper
   could package this invariant and surface overflow as a resync outcome.
3. Every topology delta is exposed faithfully, but consumers must implement a
   large match and know which events require a full snapshot. A generated tree
   reducer, or a `WorkspaceState` helper with `apply(Event)`, would prevent
   subtly divergent client models.
4. Overflow and transport loss require hand-written resubscribe, fresh
   snapshots, retry reporting, and notification de-duplication. A reconnecting
   subscription with explicit `Resynced` and `Disconnected` states would remove
   repeated lifecycle code.
5. The blocking client has no process-signal or async cancellation integration.
   `StreamCloser` is useful once a stream exists, but this dependency-free app
   still needs timeout polling to observe a graceful `q` shutdown.
6. All entity identifiers are aliases of `u64`. Distinct `WorkspaceId`,
   `ScreenId`, `PaneId`, and `SurfaceId` newtypes would catch target mix-ups
   without adding a runtime dependency.
7. `RequiredNullable<T>` preserves the wire distinction correctly, but reading
   a nullable value requires `into_option()` or access through the wrapper.
   `as_deref`, `is_null`, and `From<Option<T>>` would make display code smaller.
8. SDK connection discovery is useful, but CLI argument parsing for the common
   `--session`/`--socket` choice is left to each Rust application.
