import Foundation

extension DaemonStore {
    /// The status the sidebar row of `workspace` draws, or nil.
    public func status(of workspace: WorkspaceModel) -> WorkspaceStatusSnapshot? {
        guard let id = workspace.resourceID else { return nil }
        return workspaceStatus[id]
    }

    /// Applies one `session.events` status change. A snapshot replaces
    /// everything; an empty status (everything cleared) drops its row.
    func applyWorkspaceStatus(_ change: WorkspaceStatusChange) {
        switch change {
        case .reset(let snapshots):
            let next = Dictionary(snapshots.filter { !$0.isEmpty }.map { ($0.workspaceID, $0) }, uniquingKeysWith: { $1 })
            if next != workspaceStatus { workspaceStatus = next }
        case .changes(let items):
            var next = workspaceStatus
            for item in items {
                switch item {
                case .upsert(let snapshot): next[snapshot.workspaceID] = snapshot.isEmpty ? nil : snapshot
                case .delete(let id): next[id] = nil
                }
            }
            if next != workspaceStatus { workspaceStatus = next }
        case .stale:
            guard let connection = driver?.connection else { return }
            // task-owner: one fire-and-forget write on the connection actor; its snapshot arrives as `.reset`
            Task { await connection.reopenSessionEvents() }
        }
    }
}
