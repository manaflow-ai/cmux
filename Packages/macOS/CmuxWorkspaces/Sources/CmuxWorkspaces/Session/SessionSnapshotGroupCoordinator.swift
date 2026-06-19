public import Foundation

/// Pure snapshot math for the workspace-group half of a window's session
/// snapshot: assembling persisted ``SessionWorkspaceGroupSnapshot`` values
/// from the live groups at save time, and rebuilding ``WorkspaceGroup``
/// values from a persisted snapshot at restore time.
///
/// Both directions are deterministic transforms over value types only. The
/// app shell gathers the live workspace/group state, calls these methods, and
/// applies the result to its `@Published`/`@Observable` stores; the
/// coordinator never reads or mutates live `Workspace` objects, the
/// notification store, or the file system. This is the "plan from a snapshot,
/// apply on the owning actor" split the refactor uses to keep the moved logic
/// machine-diffable against the legacy bodies and unit-testable without the
/// app target.
///
/// Isolation: a stateless `Sendable` struct constructed at the composition
/// root and held by the app shell. It carries no mutable state; every method
/// is a pure function of its inputs, so there is nothing to protect with an
/// actor or a lock.
public struct SessionSnapshotGroupCoordinator: Sendable {
    /// Creates the coordinator. It holds no dependencies; the explicit
    /// initializer keeps the type a real injected instance rather than a
    /// static-method namespace.
    public init() {}

    /// Assembles the persisted group snapshots for a save.
    ///
    /// Mirrors the legacy `TabManager.sessionSnapshot` group-assembly block
    /// byte-for-byte: it keeps only groups that still own at least one
    /// restorable member (`occupiedGroupIds`), preserves `groups` order, and
    /// records the anchor's 0-based index among its restorable members (in tab
    /// order) so restore stays stable across UUID rotation. Returns nil when
    /// no group survives, matching the legacy `snapshots.isEmpty ? nil`.
    ///
    /// - Parameters:
    ///   - groups: The window's groups in sidebar/tab order.
    ///   - occupiedGroupIds: Group ids that still own a restorable member.
    ///   - restorableMemberIdsByGroupId: Per-group ordered restorable member
    ///     ids (tab order), used to resolve the anchor's member index.
    /// - Returns: The persisted group snapshots, or nil when none survive.
    public func assembleGroupSnapshots(
        groups: [WorkspaceGroup],
        occupiedGroupIds: Set<UUID>,
        restorableMemberIdsByGroupId: [UUID: [UUID]]
    ) -> [SessionWorkspaceGroupSnapshot]? {
        let snapshots = groups
            .filter { occupiedGroupIds.contains($0.id) }
            .map { group -> SessionWorkspaceGroupSnapshot in
                let memberIds = restorableMemberIdsByGroupId[group.id] ?? []
                let anchorIndex = memberIds.firstIndex(of: group.anchorWorkspaceId)
                return SessionWorkspaceGroupSnapshot(
                    id: group.id,
                    name: group.name,
                    isCollapsed: group.isCollapsed,
                    anchorWorkspaceId: group.anchorWorkspaceId,
                    anchorMemberIndex: anchorIndex,
                    isPinned: group.isPinned,
                    customColor: group.customColor,
                    iconSymbol: group.iconSymbol
                )
            }
        return snapshots.isEmpty ? nil : snapshots
    }

    /// Rebuilds the live groups from a persisted snapshot during restore.
    ///
    /// Mirrors the legacy `TabManager.restoreSessionSnapshot` group-restore
    /// block byte-for-byte: it drops snapshots whose group has no restored
    /// members, dedupes by group id (first wins), and resolves each anchor by
    /// preferring the restore-stable `anchorMemberIndex`, then the in-process
    /// `anchorWorkspaceId` hint (when it still names a member), then the first
    /// member in tab order for very old snapshots that carry neither. `isPinned`
    /// defaults to false when the snapshot omits it.
    ///
    /// - Parameters:
    ///   - groupSnapshots: The persisted group snapshots, or nil when the
    ///     snapshot carried no groups.
    ///   - memberIdsByGroupId: Per-group restored member ids (tab order),
    ///     keyed by the snapshot's group id.
    /// - Returns: The rebuilt groups; empty when `groupSnapshots` is nil.
    public func restoreGroups(
        groupSnapshots: [SessionWorkspaceGroupSnapshot]?,
        memberIdsByGroupId: [UUID: [UUID]]
    ) -> [WorkspaceGroup] {
        guard let groupSnapshots else { return [] }
        var seen: Set<UUID> = []
        return groupSnapshots.compactMap { groupSnapshot in
            guard let members = memberIdsByGroupId[groupSnapshot.id], !members.isEmpty,
                  seen.insert(groupSnapshot.id).inserted else { return nil }
            // Resolve anchor: prefer the restore-stable index (since each
            // restored workspace gets a fresh UUID, the old anchorWorkspaceId
            // rarely matches). Fall back to the in-process UUID hint, then to
            // "first member by tab order" for very old snapshots that pre-date
            // both fields.
            let anchorId: UUID = {
                if let index = groupSnapshot.anchorMemberIndex,
                   members.indices.contains(index) {
                    return members[index]
                }
                if let stored = groupSnapshot.anchorWorkspaceId, members.contains(stored) {
                    return stored
                }
                return members[0]
            }()
            return WorkspaceGroup(
                id: groupSnapshot.id,
                name: groupSnapshot.name,
                isCollapsed: groupSnapshot.isCollapsed,
                isPinned: groupSnapshot.isPinned ?? false,
                anchorWorkspaceId: anchorId,
                customColor: groupSnapshot.customColor,
                iconSymbol: groupSnapshot.iconSymbol
            )
        }
    }
}
