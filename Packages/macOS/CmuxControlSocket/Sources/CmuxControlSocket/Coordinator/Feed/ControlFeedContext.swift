/// The feed-domain (workstream) slice of the control-command seam (a constituent
/// of the ``ControlCommandContext`` umbrella).
///
/// Covers the coordinator-owned Feed methods (`feed.jump`, `feed.list`). The
/// worker-lane feed methods (`feed.push`, `feed.permission.reply`,
/// `feed.question.reply`, `feed.exit_plan.reply`) block or await on the socket
/// worker and stay on the app-side worker path; they are NOT part of this seam.
///
/// The app target (today `TerminalController`, the interim composition owner;
/// later `TerminalControlComposition`) conforms by reaching `FeedCoordinator`
/// state. `feed.jump` is asynchronous and actor-owned so hook-session reads do
/// not run on the socket worker or main actor. `feed.list` remains main-actor
/// isolated because it snapshots the observable Feed store.
@MainActor
public protocol ControlFeedContext: AnyObject {
    /// Asynchronously resolves a workstream id without performing hook-session
    /// filesystem I/O on the socket worker or the main actor.
    nonisolated func controlFeedResolvePossibleSurfaceAsync(
        workstreamID: String
    ) async -> Bool

    /// Snapshots the workstream feed items for `feed.list`, already shaped as the
    /// per-item JSON the legacy `FeedSocketEncoding.itemDict` produced and bridged
    /// to ``JSONValue`` so the encoded wire bytes match.
    ///
    /// - Parameter pendingOnly: When `true`, only pending items are returned
    ///   (mirrors the legacy `pending_only` filter on `FeedCoordinator.snapshot`).
    /// - Returns: The feed items as JSON values, in snapshot order.
    @MainActor
    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue]
}
