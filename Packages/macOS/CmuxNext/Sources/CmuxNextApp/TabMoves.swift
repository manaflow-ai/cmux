import CmuxNextDaemon
import Foundation

/// Daemon command sequences for tab moves. With `tab-drag-v1` every outcome
/// is one atomic command; older daemons get a documented fallback (split or
/// new column spawns a pane, the tab moves in, the spawned terminal closes).
enum TabMoves {
    /// Reorder or cross-pane move with an optimistic patch.
    static func move(_ tab: TabModel, to pane: PaneModel, index: Int, services: AppServices,
                     completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let surface = tab.surface, target = pane.handle
        let echoes = services.daemon.supports(DaemonCapabilities.tabDrag)
        Task {
            let ok = await services.daemon.perform("move-tab", patch: .moveTab(surface: surface, toPane: target, index: index),
                                                   expectEcho: echoes) { connection, transaction in
                _ = try await connection.moveTab(surface, to: target, index: index, transaction: echoes ? transaction : nil)
            }
            completion(ok)
        }
    }

    static func toNewSplit(_ tab: TabModel, pane: PaneModel, edge: PaneEdge, services: AppServices,
                           completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let surface = tab.surface, paneHandle = pane.handle
        Task {
            let ok = await services.daemon.run("move-tab-to-split") { connection in
                do {
                    _ = try await connection.moveTabToSplit(surface, pane: paneHandle, edge: edge)
                } catch DaemonError.missingCapabilities {
                    let direction: SplitDirection = edge == .left || edge == .right ? .right : .down
                    let created = try await connection.split(paneHandle, direction: direction)
                    let newPane = try await adopt(surface, into: created, connection: connection)
                    if edge == .left || edge == .top { try await connection.swapPane(newPane, with: .pane(paneHandle)) }
                }
            }
            completion(ok)
        }
    }

    static func toNewColumn(_ tab: TabModel, rightOf pane: PaneModel, services: AppServices,
                            completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let surface = tab.surface, paneHandle = pane.handle
        Task {
            let ok = await services.daemon.run("move-tab-to-column") { connection in
                do {
                    _ = try await connection.moveTabToColumn(surface, target: .pane(paneHandle))
                } catch DaemonError.missingCapabilities {
                    let created = try await connection.newColumn(rightOf: paneHandle)
                    _ = try await adopt(surface, into: created, connection: connection)
                }
            }
            completion(ok)
        }
    }

    /// Moves the tab into a new workspace. Returns the new workspace key.
    static func toNewWorkspace(_ tab: TabModel, services: AppServices) async -> WorkspaceKey? {
        let surface = tab.surface
        guard let connection = services.daemon.connection else { return nil }
        do {
            let before = Set(services.daemon.store.workspaces.compactMap(\.key))
            let result = try await connection.moveTabToNewWorkspace(surface)
            if let key = result.key { return key }
            let tree = try await connection.listWorkspaces()
            return tree.workspaces.compactMap(\.key).first { !before.contains($0) }
        } catch {
            services.daemon.logger.error("move-tab-to-new-workspace failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func toWorkspace(_ tab: TabModel, workspace: WorkspaceModel, services: AppServices,
                            completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let surface = tab.surface, handle = workspace.handle
        Task {
            let ok = await services.daemon.run("move-tab-to-workspace") { connection in
                _ = try await connection.moveTab(surface, toWorkspace: handle)
            }
            completion(ok)
        }
    }

    /// Fallback helper: moves `surface` into the pane that holds the freshly
    /// spawned `created` tab, then closes the spawned terminal.
    private static func adopt(_ surface: SurfaceID, into created: SurfaceCreated,
                              connection: DaemonConnection) async throws -> PaneID {
        let tree = try await connection.listWorkspaces()
        let panes = tree.workspaces.flatMap(\.screens).flatMap(\.panes)
        guard let pane = panes.first(where: { $0.tabs.contains { $0.surface == created.surface } }) else {
            throw DaemonError.malformedResponse("spawned pane for surface \(created.surface) not found")
        }
        _ = try await connection.moveTab(surface, to: pane.id, index: 0)
        if let terminal = created.terminalID {
            try await connection.closeTerminal(terminal, incarnation: created.terminalIncarnation)
        } else {
            try await connection.closeTab(created.surface)
        }
        return pane.id
    }
}
