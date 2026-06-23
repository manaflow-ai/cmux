#if DEBUG
/// The per-window workspace-switch trace context the `TabManager` carries while
/// a switch is in flight, handed to the handoff/unfocus trace formatters so they
/// can prepend the `id=<id> dt=<ms>` prefix to a `ws.*` debug trace line.
///
/// The app-target `TabManager` owns the live snapshot
/// (`debugCurrentWorkspaceSwitchSnapshot()` returns the in-flight switch id and
/// its `CACurrentMediaTime` start). It maps that tuple into this `Sendable`
/// value and computes the elapsed milliseconds itself, then passes both to the
/// ``PendingWorkspaceUnfocusEvent/traceLine(switchSnapshot:elapsedMs:)`` /
/// ``WorkspaceHandoffEvent/traceLine(switchSnapshot:elapsedMs:)`` formatters.
/// `nil` means no switch is in flight, which selects the legacy `id=none`
/// branch. `#if DEBUG`-only because the trace log it feeds is itself debug-only.
public struct WorkspaceSwitchTraceSnapshot: Sendable {
    /// The in-flight workspace-switch id, emitted verbatim as `id=<id>`.
    public let id: UInt64

    /// Creates a trace snapshot from the in-flight switch id.
    /// - Parameter id: The workspace-switch id the `TabManager` is tracking.
    public init(id: UInt64) {
        self.id = id
    }
}
#endif
