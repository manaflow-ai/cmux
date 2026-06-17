/// The feed-domain (workstream) slice of the control-command seam (a constituent
/// of the ``ControlCommandContext`` umbrella).
///
/// Covers only the MAIN-ACTOR feed methods (`feed.jump`, `feed.list`). The
/// worker-lane feed methods (`feed.push`, `feed.permission.reply`,
/// `feed.question.reply`, `feed.exit_plan.reply`) block or await on the socket
/// worker and stay on the app-side worker path; they are NOT part of this seam.
///
/// The app target (today `TerminalController`, the interim composition owner;
/// later `TerminalControlComposition`) conforms by reaching `FeedCoordinator`
/// state. Every method is `@MainActor` because its conformer lives on the main
/// actor and the coordinator runs there too, so these are plain in-isolation
/// calls — the per-read `v2MainSync` hops the legacy command bodies used
/// disappear once the domain moves onto the coordinator.
@MainActor
public protocol ControlFeedContext: AnyObject {
    /// Resolves whether a workstream id maps to a known cmux surface for
    /// `feed.jump`, mirroring the legacy `FeedCoordinator.resolvePossibleSurface`
    /// probe (the MVP returns only whether the id is known so callers can show a
    /// toast).
    ///
    /// - Parameter workstreamID: The caller-supplied `workstream_id`, untrimmed,
    ///   exactly as the legacy body forwarded it.
    /// - Returns: Whether the id matched a possible surface.
    func controlFeedResolvePossibleSurface(workstreamID: String) -> Bool

    /// Snapshots the workstream feed items for `feed.list`, already shaped as the
    /// per-item JSON the legacy `FeedSocketEncoding.itemDict` produced and bridged
    /// to ``JSONValue`` so the encoded wire bytes match.
    ///
    /// - Parameter pendingOnly: When `true`, only pending items are returned
    ///   (mirrors the legacy `pending_only` filter on `FeedCoordinator.snapshot`).
    /// - Returns: The feed items as JSON values, in snapshot order.
    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue]
}
