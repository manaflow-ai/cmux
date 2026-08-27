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
/// state. The real socket uses the asynchronous `feed.jump` seam so hook-session
/// reads do not run on the main actor; in-process worker callers use the
/// synchronous seam after establishing their off-main execution context.
/// `feed.list` remains main-actor isolated because it snapshots the observable
/// Feed store.
@MainActor
public protocol ControlFeedContext: AnyObject {
    /// Localized validation text for a malformed `feed.jump` request. The app
    /// supplies this value so the package does not bind localization to its
    /// resource bundle.
    nonisolated func controlFeedInvalidJumpMessage() -> String

    /// Asynchronously resolves a workstream id without performing hook-session
    /// filesystem I/O on the socket worker or the main actor.
    nonisolated func controlFeedResolvePossibleSurfaceAsync(
        workstreamID: String
    ) async -> Bool

    /// Synchronously resolves a workstream id for in-process callers that
    /// cannot suspend. The caller must already be off the main actor.
    nonisolated func controlFeedResolvePossibleSurface(
        workstreamID: String
    ) -> Bool

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
