import Foundation

/// Who asked for a workspace move. Only `.user` moves change the session
/// priority rank; cmux's own placement passes `.automatic`.
enum WorkspaceMoveOrigin: Sendable {
    case user
    case automatic
}

/// Session priority rank wiring for a window: user moves record into
/// `sessionPriorityRank`, and the rank persists with the session.
extension TabManager {
    /// The window's workspaces in session priority order: pinned workspaces
    /// first, each tier in rank order.
    var sessionPriorityEffectiveOrder: [UUID] {
        let order = sessionPriorityRank.effectiveOrder(visibleOrder: tabs.map(\.id))
        let pinnedIds = Set(tabs.filter(\.isPinned).map(\.id))
        return order.filter { pinnedIds.contains($0) } + order.filter { !pinnedIds.contains($0) }
    }

    /// Records a user-initiated move that left the sidebar in its current
    /// order, then tells the priority coordinator.
    ///
    /// - Parameters:
    ///   - movedIds: The workspaces the entry point moved.
    ///   - before: The visible workspace order before the move.
    ///   - movingUp: Whether the user asked to move them up or to a place;
    ///     `false` for a move down. Used only when the order did not change.
    func noteUserWorkspaceMove(movedIds: [UUID], before: [UUID], movingUp: Bool = true) {
        sessionPriorityRank.recordUserMove(
            movedIds: movedIds,
            before: before,
            after: tabs.map(\.id),
            movingUp: movingUp
        )
        SessionPriorityCoordinatorHook.userDidReorder?(self)
    }

    /// Records a user-requested explicit order (batch reorder), then tells
    /// the priority coordinator.
    func noteUserWorkspaceOrder(_ orderedIds: [UUID]) {
        sessionPriorityRank.recordUserOrder(orderedIds, visibleOrder: tabs.map(\.id))
        SessionPriorityCoordinatorHook.userDidReorder?(self)
    }

    // MARK: - Session persistence

    /// Stamps each workspace snapshot with its position in the rank over the
    /// restorable workspaces (unpartitioned; pinning applies on read).
    ///
    /// - Parameters:
    ///   - snapshots: The workspace snapshots, aligned with `workspaceIds`.
    ///   - workspaceIds: The restorable workspaces' ids in sidebar order.
    func sessionPriorityIndexed(
        _ snapshots: [SessionWorkspaceSnapshot],
        workspaceIds: [UUID]
    ) -> [SessionWorkspaceSnapshot] {
        let order = sessionPriorityRank.effectiveOrder(visibleOrder: workspaceIds)
        let indexById = Dictionary(
            order.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return zip(snapshots, workspaceIds).map { snapshot, workspaceId in
            var indexed = snapshot
            indexed.sessionPriorityIndex = indexById[workspaceId]
            return indexed
        }
    }

    /// Rebuilds the rank from restored snapshots' priority indexes. Call after
    /// the restored workspaces are assigned to `tabs`, so the setter's
    /// insertion order does not decide the rank.
    ///
    /// - Parameters:
    ///   - snapshots: The restored workspace snapshots.
    ///   - restoredWorkspaceIds: The live ids the snapshots restored into,
    ///     aligned with `snapshots`.
    func restoreSessionPriorityRank<Snapshots: Sequence>(
        from snapshots: Snapshots,
        restoredWorkspaceIds: [UUID]
    ) where Snapshots.Element == SessionWorkspaceSnapshot {
        let ranked = zip(snapshots, restoredWorkspaceIds)
            .compactMap { snapshot, workspaceId in
                snapshot.sessionPriorityIndex.map { (index: $0, id: workspaceId) }
            }
            .enumerated()
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
            .map(\.element.id)
        var rank = SessionPriorityRank(recordedOrder: ranked)
        rank.sync(visibleOrder: tabs.map(\.id))
        sessionPriorityRank = rank
    }
}
