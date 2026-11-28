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

    /// The pane in workspace `key` that holds `surface`, which `connection`'s last command made (a split's new pane).
    /// The store answers first. When it lists the workspace without that pane (it said it caught up with the reply,
    /// yet trails the split under load: the classic re-upgrade red of 2026-11-22, "pane for surface 18 not found"),
    /// the daemon's own list is asked once before the pane counts as gone.
    public func pane(holding surface: SurfaceID, in key: WorkspaceKey, after connection: DaemonConnection) async throws -> PaneID {
        if let pane = try await shape(of: key, after: connection)?.pane(holding: surface) { return pane }
        let listed = try await connection.listWorkspaces().workspaces.first { $0.key == key }.map(WorkspaceShape.init)
        guard let pane = listed?.pane(holding: surface) else {
            let why = listed == nil ? "the daemon lists no such workspace" : "the daemon lists the workspace without it"
            throw DaemonError.malformedResponse("pane for surface \(surface) not found (\(why))")
        }
        return pane
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
