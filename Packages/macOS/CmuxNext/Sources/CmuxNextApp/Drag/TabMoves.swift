import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import enum CmuxNextLayout.DockEdge
import enum CmuxNextLayout.DockMode
import Foundation

/// Daemon commands for tab moves. With `tab-drag-v1` every outcome is one
/// atomic command carrying the drag's client transaction (echoed in the
/// moved tab's delta). Older daemons get documented fallbacks: a split or
/// column spawns a pane, the tab moves in, the spawned terminal closes.
enum TabMoves {
    typealias Completion = @MainActor (Bool) -> Void

    /// Reorder or cross-pane move to `index` (final display index), shown
    /// at once as an intent in the store's intent log.
    static func move(_ tab: TabModel, to pane: PaneModel, index: Int, services: AppServices,
                     transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let daemon = services.machines.daemon(forTab: tab)
        // Workspaces never mix machines: a drop onto another machine's pane is refused.
        guard services.daemon(for: pane) === daemon else { return completion(false) }
        guard !refusesIncognitoCrossing(tab, to: pane, services: services) else { return completion(false) }
        let surface = tab.surface, target = pane.handle
        let current = pane.tabs.firstIndex { $0.surface == surface }
        let wire = TabMoveIndex.wireIndex(finalIndex: index, currentIndex: current)
        let echoes = daemon.supports(DaemonCapabilities.shared.tabDrag)
        services.registry.track(Task {
            let ok = await daemon.intend("move-tab", .moveTab(surface: surface, toPane: target, index: index),
                                         transaction: transaction) { connection -> Void in
                _ = try await connection.moveTab(surface, to: target, index: wire, transaction: echoes ? transaction : nil)
            } != nil
            completion(ok)
            return ok ? nil : "move-tab failed (see the app log)"
        })
    }

    /// The new tab a split of `tab`'s own pane spawns there when `tab` is
    /// its only tab: the same kind, fresh. A terminal gets a new shell in
    /// the dragged terminal's directory; a frontend browser tab gets the New
    /// Tab page with the dragged tab's engine and profile. Nil when the
    /// kind cannot respawn: remote-terminal references, daemon-rendered
    /// browser tabs, incognito tabs (their URL must stay out of the daemon),
    /// and app-local tabs (agent chats), which are not daemon tabs.
    @MainActor
    static func respawn(for tab: TabModel, in pane: PaneModel, services: AppServices) -> SplitRespawn? {
        switch tab.kind {
        case .pty:
            return .terminal(SpawnOptions(cwd: tab.cwd, workspace: services.workspaceKey(of: pane)))
        case .browser:
            guard tab.isFrontendOwned, let browserTabs = services.cache.browserTabs, !browserTabs.isIncognitoTab(tab.id),
                  case .open(let choice) = browserTabs.resolve(requested: nil, inherited: tab.browserEngine)
            else { return nil }
            return .browser(url: services.newTabAddress(for: choice), engine: choice.engine, profileID: tab.snapshot.browserProfileID)
        default:
            return nil
        }
    }

    /// New pane on `edge` of `pane` holding the tab.
    static func toNewSplit(_ tab: TabModel, pane: PaneModel, edge: PaneEdge, services: AppServices,
                           respawn: SplitRespawn? = nil,
                           transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let daemon = services.machines.daemon(forTab: tab)
        // Workspaces never mix machines: a drop onto another machine's pane is refused.
        guard services.daemon(for: pane) === daemon else { return completion(false) }
        guard !refusesIncognitoCrossing(tab, to: pane, services: services) else { return completion(false) }
        // With a respawn the source pane stays (it gets the new tab).
        switch services.splitRoom(for: pane, edge: edge, movingFrom: respawn == nil ? services.locateTab(tab.id)?.1 : nil) {
        case .split:
            break
        case .newColumn(let afterColumn, _):
            return toNewColumn(tab, anchor: pane, afterColumn: afterColumn, services: services, transaction: transaction, completion: completion)
        case .refused(let reason):
            services.registry.refuse(reason)
            return completion(false)
        }
        let surface = tab.surface, paneHandle = pane.handle
        let echoes = daemon.supports(DaemonCapabilities.shared.tabDrag)
        services.registry.track(Task {
            let ok = await daemon.request("move-tab-to-split") { connection -> Void in
                do {
                    if let respawn {
                        try await MoveTabToSplitRespawnRequest(surface: surface, pane: paneHandle, edge: edge, respawn: respawn,
                                                               transaction: echoes ? transaction : nil).send(on: connection)
                    } else {
                        _ = try await connection.moveTabToSplit(surface, pane: paneHandle, edge: edge, transaction: echoes ? transaction : nil)
                    }
                } catch DaemonError.missingCapabilities where respawn == nil {
                    try await fallbackSplit(surface, target: paneHandle, edge: edge, connection: connection)
                }
            } != nil
            completion(ok)
            return ok ? nil : "move-tab-to-split failed (see the app log)"
        })
    }

    /// New strip column after `afterColumn` (nil = right of `anchor`'s column).
    static func toNewColumn(_ tab: TabModel, anchor pane: PaneModel, afterColumn: DaemonColumnID? = nil, services: AppServices,
                            transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let daemon = services.machines.daemon(forTab: tab)
        // Workspaces never mix machines: a drop onto another machine's pane is refused.
        guard services.daemon(for: pane) === daemon else { return completion(false) }
        guard !refusesIncognitoCrossing(tab, to: pane, services: services) else { return completion(false) }
        let surface = tab.surface, paneHandle = pane.handle
        let echoes = daemon.supports(DaemonCapabilities.shared.tabDrag)
        let spawn = services.newColumnWidth(nextTo: pane, movingFrom: services.locateTab(tab.id)?.1)
        let width = spawn.width
        services.registry.track(Task {
            let ok = await daemon.request("move-tab-to-column") { connection -> Void in
                do {
                    _ = try await connection.moveTabToColumn(surface, target: .pane(paneHandle), afterColumn: afterColumn,
                                                             width: width, transaction: echoes ? transaction : nil)
                } catch DaemonError.missingCapabilities {
                    let created = try await connection.newColumn(rightOf: paneHandle, width: width)
                    _ = try await adopt(surface, into: created, connection: connection)
                }
            } != nil
            if ok { spawn.commit() }
            completion(ok)
            return ok ? nil : "move-tab-to-column failed (see the app log)"
        })
    }

    /// Moves the tab into a new column pinned to `edge` on `anchor`'s screen,
    /// in one daemon commit (move-tab-to-column with `dock`,
    /// edge-docks-v1). The column that held the edge scrolls again. Top and
    /// bottom are edge docks; `mode` nil uses `layout.dockColumnMode`, and
    /// `width` nil a third of the height for a band or the width of a new
    /// column beside the anchor for a side.
    static func toNewDockColumn(_ tab: TabModel, anchor pane: PaneModel, edge: CmuxNextLayout.DockEdge,
                                  mode: CmuxNextLayout.DockMode? = nil, width: Double? = nil, respawn: SplitRespawn? = nil,
                                  services: AppServices,
                                  transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let daemon = services.machines.daemon(forTab: tab)
        guard services.daemon(for: pane) === daemon, daemon.supports(DaemonCapabilities.shared.edgeDocks),
              !refusesIncognitoCrossing(tab, to: pane, services: services) else { return completion(false) }
        let surface = tab.surface, paneHandle = pane.handle
        let overlay = mode.map { $0 == .overlay } ?? (DesignSettings.shared.dockColumnMode == .overlay)
        let pin = DockSnapshot(edge: DockSnapshot.Edge(rawValue: edge.rawValue) ?? .right, mode: overlay ? .overlay : .docked)
        // A band's size is a share of the screen height; a side column takes
        // the width a new column next to the anchor would take.
        let spawn = edge.isBand || width != nil ? nil
            : services.newColumnWidth(nextTo: pane, movingFrom: services.locateTab(tab.id)?.1)
        let width = width ?? spawn?.width ?? 0.3
        services.registry.track(Task {
            let ok = await daemon.request("move-tab-to-column") { connection -> Void in
                if let respawn {
                    let move = MoveTabToColumnRequest(surface: surface, target: .pane(paneHandle), width: width, dock: pin,
                                                      transaction: transaction)
                    try await MoveTabToColumnRespawnRequest(move, respawn: respawn).send(on: connection)
                } else {
                    _ = try await connection.moveTabToColumn(surface, target: .pane(paneHandle), width: width, dock: pin,
                                                             transaction: transaction)
                }
            } != nil
            if ok { spawn?.commit() }
            completion(ok)
            return ok ? nil : "move-tab-to-column failed (see the app log)"
        })
    }

    /// Moves the tab into a new workspace at root `index`. Returns the new
    /// workspace key, or nil on failure. Daemons without `tab-drag-v1`
    /// create it unplaced; it is then moved into place. Workspace groups are
    /// personal, so the new workspace never joins a shared group.
    static func toNewWorkspace(_ tab: TabModel, index: Int? = nil, services: AppServices,
                               transaction: ClientTransactionID = .generate()) async -> WorkspaceKey? {
        let daemon = services.machines.daemon(forTab: tab)
        let surface = tab.surface
        let echoes = daemon.supports(DaemonCapabilities.shared.tabDrag)
        let before = Set(daemon.store.workspaces.compactMap(\.key))
        let name = newWorkspaceName(for: tab, services: services)
        // The daemon names the workspace in the move's commit when it can.
        let inCommit = daemon.supports(DaemonCapabilities.shared.tabWorkspaceName)
        let key = await daemon.request("move-tab-to-new-workspace") { connection -> WorkspaceKey? in
            let result = try await connection.moveTabToNewWorkspace(surface, group: nil, index: index, name: inCommit ? name : nil,
                                                                    transaction: echoes ? transaction : nil)
            let created: WorkspaceKey?
            if let resultKey = result.key {
                created = resultKey
            } else {
                created = try await connection.listWorkspaces().workspaces.compactMap(\.key).first { !before.contains($0) }
            }
            if !echoes, let created, let index { _ = try await connection.moveWorkspace(created, to: index) }
            // A daemon without `tab-workspace-name-v1`: a second command. The
            // move already happened, so a failed rename leaves the default
            // name and does not fail the move.
            if !inCommit, let created, let name { _ = try? await connection.renameWorkspace(created, to: name) }
            return created
        }
        return key ?? nil
    }

    /// The name a workspace made from `tab` takes: the tab's, or, when
    /// `tab` is its workspace's last daemon tab, the workspace's own name
    /// when the user named it (the workspace closes behind the move).
    static func newWorkspaceName(for tab: TabModel, services: AppServices) -> String? {
        let input = nameInput(tab, services: services)
        guard let source = services.workspaceID(ofTab: tab.id).flatMap(services.workspace(id:)),
              source.screens.flatMap(\.panes).flatMap(\.tabs).count == 1 else { return NewWorkspaceName.forTab(input) }
        return NewWorkspaceName.forLastTab(workspaceName: source.name, workspaceTitle: source.title, tab: input)
    }

    /// What `NewWorkspaceName` reads from `tab`: the browser's live page
    /// title comes from the app's renderer, the rest from the store.
    static func nameInput(_ tab: TabModel, services: AppServices) -> NewWorkspaceName.Tab {
        let kind: NewWorkspaceName.Tab.Kind = switch tab.kind {
        case .pty: .terminal
        case .browser: .browser
        case .remoteTerminal: .remoteTerminal
        // A conversation or a kind this app does not know: its title still names it.
        case .conversation, .other: .terminal
        }
        return NewWorkspaceName.Tab(kind: kind, userName: tab.name, title: tab.title,
                                    pageTitle: tab.kind == .browser ? services.cache.existingBrowser(tab.id)?.tab.state.title : nil,
                                    url: tab.url, cwd: tab.cwd)
    }

    static func toWorkspace(_ tab: TabModel, workspace: WorkspaceModel, services: AppServices,
                            transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let daemon = services.machines.daemon(forTab: tab)
        if services.windows.crossesIncognito(from: services.workspaceID(ofTab: tab.id), to: workspace.id) {
            services.registry.refuse(RefusalStrings.incognitoMismatch)
            return completion(false)
        }
        guard let destination = services.machines.daemon(forWorkspace: workspace.id) else { return completion(false) }
        guard destination === daemon else {
            // Another session: move the reference, never the process
            // (plans/cmux-next/data-model.md 1.5).
            return services.remoteTerminals.move(tab, from: daemon, to: workspace, on: destination, completion: completion)
        }
        let surface = tab.surface, handle = workspace.handle
        let echoes = daemon.supports(DaemonCapabilities.shared.tabDrag)
        services.registry.track(Task {
            let ok = await daemon.request("move-tab-to-workspace") { connection -> Void in
                _ = try await connection.moveTab(surface, toWorkspace: handle, transaction: echoes ? transaction : nil)
            } != nil
            completion(ok)
            return ok ? nil : "move-tab-to-workspace failed (see the app log)"
        })
    }

    /// True (and refused with a message) when `tab` would move between an
    /// incognito window and a normal one.
    static func refusesIncognitoCrossing(_ tab: TabModel, to pane: PaneModel, services: AppServices) -> Bool {
        guard services.crossesIncognito(tab, to: pane) else { return false }
        services.registry.refuse(RefusalStrings.incognitoMismatch)
        return true
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
}
