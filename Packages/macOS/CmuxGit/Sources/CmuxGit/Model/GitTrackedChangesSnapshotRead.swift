struct GitTrackedChangesSnapshotRead: Sendable {
    let snapshot: GitTrackedChangesSnapshot
    let isCurrent: Bool
}
