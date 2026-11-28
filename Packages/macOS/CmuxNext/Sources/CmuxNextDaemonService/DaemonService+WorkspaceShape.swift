public import CmuxNextDaemon

extension DaemonService {
    /// Workspace `key`'s panes and layouts after the last command `connection` answered, for a builder that
    /// reads what that command made (a split's new pane, a ratio's split id). From the store once it holds every
    /// event the daemon sent before that reply: O(that workspace). The daemon's whole tree (`list-workspaces`)
    /// holds every workspace, so a read of it for each workspace an import makes grew with the session, and every
    /// other request waited behind it (#32408); it is read only when the store did not catch up.
    ///
    /// - Parameters:
    ///   - key: The workspace the builder fills.
    ///   - connection: The connection that answered the builder's last command.
    /// - Returns: The workspace's shape, or nil when neither the store nor the daemon lists it.
    public func shape(of key: WorkspaceKey, after connection: DaemonConnection) async throws -> WorkspaceShape? {
        if await appliedThroughReply(on: connection, after: "workspace layout"), let workspace = store.workspace(key: key) {
            return WorkspaceShape(workspace)
        }
        return try await connection.listWorkspaces().workspaces.first { $0.key == key }.map(WorkspaceShape.init)
    }

    /// Names tab `surface` of workspace `key`. A terminal whose shell ended before the rename reached it took its tab
    /// with it: a refused rename for a tab the workspace no longer lists is not an error. Only a refusal reads the shape.
    public func renameTab(_ surface: SurfaceID, to name: String, in key: WorkspaceKey, on connection: DaemonConnection) async throws {
        do {
            try await connection.renameTab(surface, to: name)
        } catch {
            let surfaces = try await shape(of: key, after: connection)?.screens.flatMap(\.panes).flatMap(\.surfaces) ?? []
            if surfaces.contains(surface) { throw error }
        }
    }
}
