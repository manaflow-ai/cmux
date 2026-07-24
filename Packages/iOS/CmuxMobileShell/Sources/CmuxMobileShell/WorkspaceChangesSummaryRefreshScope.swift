/// Selects which workspace ids should refresh after one workspace-list apply.
enum WorkspaceChangesSummaryRefreshScope: Sendable, Equatable {
    /// The applied response is authoritative for the full workspace list.
    case fullSnapshot
    /// Only these workspace records changed in an applied delta.
    case workspaceDelta([String])
    /// The applied delta changed groups without changing workspace records.
    case groupOnlyDelta

    /// Resolves the ids that should refresh for the applied response.
    /// - Parameter fullSnapshotWorkspaceIDs: All ids in the projected response.
    /// - Returns: Full-snapshot ids, delta ids, or an empty group-only result.
    func workspaceIDs(fullSnapshotWorkspaceIDs: [String]) -> [String] {
        switch self {
        case .fullSnapshot:
            fullSnapshotWorkspaceIDs
        case .workspaceDelta(let workspaceIDs):
            workspaceIDs
        case .groupOnlyDelta:
            []
        }
    }
}
