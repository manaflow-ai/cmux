/// The workspaces of a new snapshot that differ from the last applied one
/// (``SnapshotMemo/applied``): new ones, and ones whose snapshot changed. Computed off the main
/// thread for a live resync (the comparison reads the whole tree), then applied on the main actor
/// with the store's own dirty set.
nonisolated struct SnapshotDiff: Sendable {
    /// The memo revision it compared against; a diff of another revision is recomputed.
    let revision: UInt64
    /// Identities of the workspaces that are new or changed.
    let changed: Set<String>

    /// Compares `tree` with `applied`, off the caller's actor.
    @concurrent
    static func computed(_ tree: DaemonTree, against applied: [String: WorkspaceSnapshot], revision: UInt64) async -> SnapshotDiff {
        compute(tree, against: applied, revision: revision)
    }

    /// Compares `tree` with `applied` on the calling thread.
    static func compute(_ tree: DaemonTree, against applied: [String: WorkspaceSnapshot], revision: UInt64) -> SnapshotDiff {
        var changed = Set<String>()
        for workspace in tree.workspaces {
            let id = WorkspaceModel.identity(workspace)
            if applied[id] != workspace { changed.insert(id) }
        }
        return SnapshotDiff(revision: revision, changed: changed)
    }
}
