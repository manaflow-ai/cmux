/// An immutable foreground-workspace membership snapshot used to prune summary state.
struct WorkspaceChangesSummaryWorkspaceSet: Sendable {
    private let identifiers: Set<String>

    init(workspaceIDs: [String]) {
        identifiers = Set(workspaceIDs.filter { !$0.isEmpty })
    }

    func contains(_ workspaceID: String) -> Bool {
        identifiers.contains(workspaceID)
    }

    func workspaceIDs(retaining candidates: [String]) -> [String] {
        candidates.filter(identifiers.contains)
    }

    func values<Value>(retaining values: [String: Value]) -> [String: Value] {
        values.filter { identifiers.contains($0.key) }
    }

    func scope(
        retaining scope: WorkspaceChangesSummaryRefreshScope
    ) -> WorkspaceChangesSummaryRefreshScope {
        switch scope {
        case .fullSnapshot, .groupOnlyDelta:
            return scope
        case .workspaceDelta(let workspaceIDs):
            return .workspaceDelta(self.workspaceIDs(retaining: workspaceIDs))
        }
    }
}
