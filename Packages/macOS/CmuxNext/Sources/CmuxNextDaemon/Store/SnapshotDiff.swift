/// The workspaces of a new snapshot that differ from the last applied one
/// (``SnapshotMemo/applied``): new ones, changed ones, and the ones gone. Computed off the main
/// thread for a live resync (the comparison reads the whole tree), then applied on the main actor
/// with the store's own dirty set; the memo then takes only these entries, so main never compares
/// or copies the unchanged workspaces.
nonisolated struct SnapshotDiff: Sendable {
    /// The memo revision it compared against; a diff of another revision is recomputed.
    let revision: UInt64
    /// The new and changed workspaces' snapshots, by identity (``WorkspaceModel/identity(_:)``).
    let changed: [String: WorkspaceSnapshot]
    /// Identities the memo holds that the snapshot no longer has.
    let removed: Set<String>
    /// The snapshot's workspace identities in its order (the memo's order after it applies).
    let order: [String]
    /// The snapshot lists the memo's workspaces in the memo's order: none new, none gone, none moved.
    let sameOrder: Bool

    /// Compares `tree` with `applied`, off the caller's actor.
    @concurrent
    static func computed(_ tree: DaemonTree, against applied: [String: WorkspaceSnapshot], order: [String],
                         revision: UInt64) async -> SnapshotDiff {
        compute(tree, against: applied, order: order, revision: revision)
    }

    /// Compares `tree` with `applied` on the calling thread.
    static func compute(_ tree: DaemonTree, against applied: [String: WorkspaceSnapshot], order memoOrder: [String],
                        revision: UInt64) -> SnapshotDiff {
        var changed: [String: WorkspaceSnapshot] = [:]
        var present = Set<String>()
        present.reserveCapacity(tree.workspaces.count)
        var order: [String] = []
        order.reserveCapacity(tree.workspaces.count)
        for workspace in tree.workspaces {
            let id = WorkspaceModel.identity(workspace)
            present.insert(id)
            order.append(id)
            // The last of a repeated identity wins, as in the memo a full apply builds.
            if applied[id] != workspace { changed[id] = workspace } else { changed[id] = nil }
        }
        let removed = Set(applied.keys.filter { !present.contains($0) })
        return SnapshotDiff(revision: revision, changed: changed, removed: removed, order: order,
                            sameOrder: removed.isEmpty && order == memoOrder)
    }
}
