import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// Daemon commands for tab moves. With `tab-drag-v1` every outcome is one
/// atomic command carrying the drag's client transaction (echoed in the
/// moved tab's delta). Older daemons get documented fallbacks: a split or
/// column spawns a pane, the tab moves in, the spawned terminal closes.
enum TabMoves {
    typealias Completion = @MainActor (Bool) -> Void

    /// Reorder or cross-pane move to `index` (final display index), with an
    /// optimistic store patch settled by the transaction echo.
    static func move(_ tab: TabModel, to pane: PaneModel, index: Int, services: AppServices,
                     transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let surface = tab.surface, target = pane.handle
        let current = pane.tabs.firstIndex { $0.surface == surface }
        let wire = TabMoveIndex.wireIndex(finalIndex: index, currentIndex: current)
        let echoes = services.daemon.supports(DaemonCapabilities.tabDrag)
        services.registry.track(Task {
            let ok = await services.daemon.commit("move-tab", patch: .moveTab(surface: surface, toPane: target, index: index),
                                                   transaction: transaction, expectEcho: echoes) { connection -> Void in
                _ = try await connection.moveTab(surface, to: target, index: wire, transaction: echoes ? transaction : nil)
            } != nil
            completion(ok)
            return ok ? nil : "move-tab failed (see the app log)"
        })
    }

    /// New pane on `edge` of `pane` holding the tab.
    static func toNewSplit(_ tab: TabModel, pane: PaneModel, edge: PaneEdge, services: AppServices,
                           transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let surface = tab.surface, paneHandle = pane.handle
        let echoes = services.daemon.supports(DaemonCapabilities.tabDrag)
        services.registry.track(Task {
            let ok = await services.daemon.commit("move-tab-to-split", patch: .custom { _ in }, transaction: transaction,
                                                   expectEcho: echoes) { connection -> Void in
                do {
                    _ = try await connection.moveTabToSplit(surface, pane: paneHandle, edge: edge, transaction: echoes ? transaction : nil)
                } catch DaemonError.missingCapabilities {
                    try await fallbackSplit(surface, target: paneHandle, edge: edge, connection: connection)
                }
            } != nil
            completion(ok)
            return ok ? nil : "move-tab-to-split failed (see the app log)"
        })
    }

    /// New niri column after `afterColumn` (nil = right of `anchor`'s column).
    static func toNewColumn(_ tab: TabModel, anchor pane: PaneModel, afterColumn: DaemonColumnID? = nil, services: AppServices,
                            transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let surface = tab.surface, paneHandle = pane.handle
        let echoes = services.daemon.supports(DaemonCapabilities.tabDrag)
        services.registry.track(Task {
            let ok = await services.daemon.commit("move-tab-to-column", patch: .custom { _ in }, transaction: transaction,
                                                   expectEcho: echoes) { connection -> Void in
                do {
                    _ = try await connection.moveTabToColumn(surface, target: .pane(paneHandle), afterColumn: afterColumn,
                                                             transaction: echoes ? transaction : nil)
                } catch DaemonError.missingCapabilities {
                    let created = try await connection.newColumn(rightOf: paneHandle)
                    _ = try await adopt(surface, into: created, connection: connection)
                }
            } != nil
            completion(ok)
            return ok ? nil : "move-tab-to-column failed (see the app log)"
        })
    }

    /// Moves the tab into a new workspace at root `index` (in `group` when
    /// set). Returns the new workspace key, or nil on failure. Daemons
    /// without `tab-drag-v1` create it unplaced; it is then moved into place.
    static func toNewWorkspace(_ tab: TabModel, group: WorkspaceGroupID? = nil, index: Int? = nil, services: AppServices,
                               transaction: ClientTransactionID = .generate()) async -> WorkspaceKey? {
        let surface = tab.surface
        let echoes = services.daemon.supports(DaemonCapabilities.tabDrag)
        let before = Set(services.daemon.store.workspaces.compactMap(\.key))
        let key = await services.daemon.commit("move-tab-to-new-workspace", patch: .custom { _ in }, transaction: transaction,
                                               expectEcho: echoes) { connection -> WorkspaceKey? in
            let result = try await connection.moveTabToNewWorkspace(surface, group: group, index: index, transaction: echoes ? transaction : nil)
            let created: WorkspaceKey?
            if let resultKey = result.key {
                created = resultKey
            } else {
                created = try await connection.listWorkspaces().workspaces.compactMap(\.key).first { !before.contains($0) }
            }
            if !echoes, let created { try await place(created, group: group, index: index, connection: connection) }
            return created
        }
        return key ?? nil
    }

    static func toWorkspace(_ tab: TabModel, workspace: WorkspaceModel, services: AppServices,
                            transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let surface = tab.surface, handle = workspace.handle
        let echoes = services.daemon.supports(DaemonCapabilities.tabDrag)
        services.registry.track(Task {
            let ok = await services.daemon.commit("move-tab-to-workspace", patch: .custom { _ in }, transaction: transaction,
                                                   expectEcho: echoes) { connection -> Void in
                _ = try await connection.moveTab(surface, toWorkspace: handle, transaction: echoes ? transaction : nil)
            } != nil
            completion(ok)
            return ok ? nil : "move-tab-to-workspace failed (see the app log)"
        })
    }

    // MARK: Fallbacks (daemons without tab-drag-v1)

    /// Split, then put the tab in the new pane. `split {tab}` moves it
    /// atomically where supported; otherwise the spawned terminal is
    /// replaced by the tab. The daemon always inserts the new pane after
    /// `target`, so left and top edges swap the two panes afterwards, but
    /// only when `target` still exists: if moving the tab emptied and closed
    /// it (its last tab), the new pane already sits in its place and a swap
    /// would fail with "unknown pane/target".
    private static func fallbackSplit(_ surface: SurfaceID, target: PaneID, edge: PaneEdge, connection: DaemonConnection) async throws {
        let direction: SplitDirection = edge == .left || edge == .right ? .right : .down
        let created = try await connection.split(target, direction: direction, movingTab: surface)
        let newPane: PaneID
        if created.surface == surface {
            newPane = try await pane(holding: surface, connection: connection)
        } else {
            newPane = try await adopt(surface, into: created, connection: connection)
        }
        guard edge == .left || edge == .top, newPane != target else { return }
        let panes = try await connection.listWorkspaces().workspaces.flatMap(\.screens).flatMap(\.panes)
        guard panes.contains(where: { $0.id == target }) else { return }
        try await connection.swapPane(newPane, with: .pane(target))
    }

    /// Moves `surface` into the pane holding the freshly spawned `created`
    /// tab, then closes the spawned terminal. Returns that pane.
    private static func adopt(_ surface: SurfaceID, into created: SurfaceCreated, connection: DaemonConnection) async throws -> PaneID {
        let pane = try await pane(holding: created.surface, connection: connection)
        _ = try await connection.moveTab(surface, to: pane, index: 0)
        if let terminal = created.terminalID {
            try await connection.closeTerminal(terminal, incarnation: created.terminalIncarnation)
        } else {
            try await connection.closeTab(created.surface)
        }
        return pane
    }

    private static func pane(holding surface: SurfaceID, connection: DaemonConnection) async throws -> PaneID {
        let panes = try await connection.listWorkspaces().workspaces.flatMap(\.screens).flatMap(\.panes)
        guard let pane = panes.first(where: { $0.tabs.contains { $0.surface == surface } }) else {
            throw DaemonError.malformedResponse("pane for surface \(surface) not found")
        }
        return pane.id
    }

    /// Places a new workspace the daemon created unplaced.
    static func place(_ key: WorkspaceKey, group: WorkspaceGroupID?, index: Int?, connection: DaemonConnection) async throws {
        if let group {
            _ = try await connection.moveWorkspace(key, toGroup: group, index: index)
        } else if let index {
            _ = try await connection.moveWorkspace(key, to: index)
        }
    }
}
