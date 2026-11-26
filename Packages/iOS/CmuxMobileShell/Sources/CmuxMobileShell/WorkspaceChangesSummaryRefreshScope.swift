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

    /// Accumulates debounce requests without allowing a later narrow request to replace earlier work.
    func coalesced(with newerScope: Self) -> Self {
        switch (self, newerScope) {
        case (.fullSnapshot, _), (_, .fullSnapshot):
            return .fullSnapshot
        case (.groupOnlyDelta, let scope), (let scope, .groupOnlyDelta):
            return scope
        case (.workspaceDelta(let earlierIDs), .workspaceDelta(let newerIDs)):
            var seen: Set<String> = []
            return .workspaceDelta((earlierIDs + newerIDs).filter { id in
                !id.isEmpty && seen.insert(id).inserted
            })
        }
    }
}
