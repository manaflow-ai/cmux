public import CmuxNextDaemon

extension DaemonService {
    /// Reads one workspace's shape from this service's store once the store holds every event the daemon sent
    /// before the read (``appliedThroughReply(on:after:)``): the one workspace, whatever the session holds (#32408).
    /// When that wait does not hold (the connection dropped or is no longer this service's), the whole tree.
    public nonisolated func shapeRead(on connection: DaemonConnection) -> WorkspaceShapeRead {
        { [weak self] key in
            guard let self else { return try await connection.treeShapeRead(key) }
            return try await self.shape(of: key, on: connection)
        }
    }

    private func shape(of key: WorkspaceKey, on connection: DaemonConnection) async throws -> WorkspaceShape? {
        guard await appliedThroughReply(on: connection, after: "workspace layout read") else { return try await connection.treeShapeRead(key) }
        guard let workspace = store.workspace(id: key.rawValue), !workspace.isProvisional else { return nil }
        return WorkspaceShape(handle: workspace.handle, screens: workspace.screens.map { screen in
            WorkspaceShape.Screen(layout: screen.layout, columns: screen.columns.map(\.layout),
                                  panes: screen.panes.map { WorkspaceShape.Pane(id: $0.handle, surfaces: $0.tabs.map(\.surface)) })
        })
    }
}
