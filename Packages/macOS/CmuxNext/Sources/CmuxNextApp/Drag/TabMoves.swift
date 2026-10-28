import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
import enum CmuxNextLayout.DockEdge
import enum CmuxNextLayout.DockMode
import enum CmuxNextLayout.DockRole
import CmuxNextWorkspaceNaming
import Foundation
import CmuxNextTabs

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
        guard services.daemon(for: pane) === daemon else { return refuseOtherMachine(services, completion) }
        guard !refusesIncognitoCrossing(tab, to: pane, services: services),
              !ChatDockRules.refusesMove(tab, to: pane, services: services) else { return completion(false) }
        let surface = tab.surface, target = pane.handle
        let current = pane.tabs.firstIndex { $0.surface == surface }
        let wire = TabMoveIndex.wireIndex(finalIndex: index, currentIndex: current)
        let echoes = daemon.supports(DaemonCapability.tabDrag.rawValue)
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
    /// conversation tabs (Home and agent chats, whose source is one
    /// conversation or session), and app-local tabs, which are not daemon tabs.
    @MainActor
    static func respawn(for tab: TabModel, in pane: PaneModel, services: AppServices) -> SplitRespawn? {
        switch tab.kind {
        case .pty:
            return .terminal(SpawnOptions(cwd: tab.cwd, workspace: services.workspaceKey(of: pane)))
        case .browser:
            guard tab.isFrontendOwned, case let browserTabs = services.cache.browserTabs, !browserTabs.isIncognitoTab(tab.id),
                  case .open(let choice) = browserTabs.resolve(requested: nil, inherited: tab.browserEngine)
            else { return nil }
            return .browser(url: services.newTabAddress(for: choice), engine: choice.engine, profileID: tab.browserProfileID)
        default:
            return nil
        }
    }

    /// Every tab of `pane` dropped on its own `edge` (#22287): they stay, and the New Tab page (a new
    /// pane's default, as a person's split opens it) opens on the far side, so they end at `edge`.
    static func splitBehind(_ pane: PaneModel, edge: PaneEdge, services: AppServices, completion: @escaping Completion) {
        if ChatDockRules.isChatDock(pane, services: services) { services.registry.refuse(RefusalStrings.chatDockCannotSplit); return completion(false) }
        guard let controller = services.paneController(for: pane) else { return completion(false) }
        // One commit puts a page right or below; for a drop there the page opens on that side and the panes swap.
        let near = edge == .right || edge == .bottom
        completion(NewTabPage.split(controller, edge: near ? edge : edge.opposite, focusesPage: false, swapsBack: near))
    }

    /// New pane on `edge` of `pane` holding the tab. `roomDecided`: the
    /// caller already chose a split over a new column with the same room
    /// rule (a drag's preview did, with the emptied source pane removed),
    /// so the move runs that choice instead of deciding again. `keepFocus`: the new pane does not take focus.
    static func toNewSplit(_ tab: TabModel, pane: PaneModel, edge: PaneEdge, services: AppServices,
                           respawn: SplitRespawn? = nil, roomDecided: Bool = false, keepFocus: Bool = false,
                           transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let daemon = services.machines.daemon(forTab: tab)
        // Workspaces never mix machines: a drop onto another machine's pane is refused.
        guard services.daemon(for: pane) === daemon else { return refuseOtherMachine(services, completion) }
        guard !refusesIncognitoCrossing(tab, to: pane, services: services) else { return completion(false) }
        // Its own pane's only tab on that pane's edge (every entry point): the New Tab page opens behind it.
        if respawn == nil, let source = services.locateTab(tab.id)?.1, source.handle == pane.handle, source.tabs.count == 1 { return splitBehind(pane, edge: edge, services: services, completion: completion) }
        // With a respawn the source pane stays (it gets the new tab).
        let decision = ChatDockRules.dropSplit(roomDecided: roomDecided, intoChatDock: ChatDockRules.isChatDock(pane, services: services)) {
            services.splitRoom(for: pane, edge: edge, movingFrom: respawn == nil ? services.locateTab(tab.id)?.1 : nil)
        }
        switch decision {
        case .split:
            break
        case .newColumn(let afterColumn, _):
            return toNewColumn(tab, anchor: pane, afterColumn: afterColumn, services: services, keepFocus: keepFocus, transaction: transaction, completion: completion)
        case .refused(let reason):
            services.registry.refuse(reason)
            return completion(false)
        }
        let surface = tab.surface, paneHandle = pane.handle
        let echoes = daemon.supports(DaemonCapability.tabDrag.rawValue), emptied = respawn == nil ? services.locateTab(tab.id)?.1 : nil, sizing = services.splitSizing(for: pane, edge: edge, emptying: emptied?.tabs.count == 1 ? emptied : nil)
        // The even sizing lands with the move's echo, in the same layout update as the new split, not a
        // reply later (a visible resize after the drop, #22287); it runs only if the tab left its pane.
        // That waiter has no barrier, so a resync snapshot from before the move can settle it with the
        // tab still in its pane: the sizing then goes once the reply's events are in the store (below).
        let from = services.locateTab(tab.id)?.1.handle
        if echoes { daemon.store.whenApplied(transaction) { if let now = services.locateTab(tab.id)?.1.handle, now != from { sizing() } } }
        services.registry.track(Task {
            let ok = await daemon.request("move-tab-to-split") { connection -> Void in
                do {
                    if let respawn {
                        try await MoveTabToSplitRespawnRequest(surface: surface, pane: paneHandle, edge: edge, respawn: respawn,
                                                               transaction: echoes ? transaction : nil).send(on: connection)
                    } else {
                        _ = try await connection.moveTabToSplit(surface, pane: paneHandle, edge: edge, keepFocus: keepFocus, transaction: echoes ? transaction : nil)
                    }
                } catch DaemonError.missingCapabilities where respawn == nil {
                    try await fallbackSplit(surface, target: paneHandle, edge: edge, connection: connection)
                }
            } != nil
            if ok { daemon.whenApplied(transaction) { sizing() } }
            completion(ok)
            return ok ? nil : "move-tab-to-split failed (see the app log)"
        })
    }

    /// New strip column after `afterColumn` (nil = after the screen's last column, the daemon's default).
    static func toNewColumn(_ tab: TabModel, anchor pane: PaneModel, afterColumn: DaemonColumnID? = nil, services: AppServices, keepFocus: Bool = false,
                            transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let daemon = services.machines.daemon(forTab: tab)
        // Workspaces never mix machines: a drop onto another machine's pane is refused.
        guard services.daemon(for: pane) === daemon else { return refuseOtherMachine(services, completion) }
        guard !refusesIncognitoCrossing(tab, to: pane, services: services) else { return completion(false) }
        let surface = tab.surface, paneHandle = pane.handle
        let echoes = daemon.supports(DaemonCapability.tabDrag.rawValue)
        let spawn = services.newColumnWidth(nextTo: pane, movingFrom: services.locateTab(tab.id)?.1)
        let width = spawn.width
        services.registry.track(Task {
            // The daemon's reason reaches the caller (a CLI run's reply, the sweep's row), not only the log.
            let failure = await daemon.failure("move-tab-to-column") { connection in
                do {
                    _ = try await connection.moveTabToColumn(surface, target: .pane(paneHandle), afterColumn: afterColumn,
                                                             width: width, keepFocus: keepFocus, transaction: echoes ? transaction : nil)
                } catch DaemonError.missingCapabilities {
                    let created = try await connection.newColumn(rightOf: paneHandle, width: width)
                    _ = try await adopt(surface, into: created, connection: connection)
                }
            }
            if failure == nil { spawn.commit() }
            completion(failure == nil)
            return failure
        })
    }

    /// A new left dock's share of the window width (cx-ihyx2).
    static let leftDockWidth = 0.5

    /// Moves the tab into a new column pinned to `edge` on `anchor`'s screen,
    /// in one daemon commit (move-tab-to-column with `dock`: dock-columns-v1,
    /// and edge-docks-v1 for top and bottom; an older daemon would ignore
    /// `dock` and make a plain column, so it is refused here). The column that held the edge scrolls again. Top and
    /// bottom are edge docks; `mode` nil uses `layout.dockColumnMode`, and
    /// `width` nil a third of the height for a band, half the window for a
    /// left dock, or the width of a new column beside the anchor for a right dock. `role` marks the chat dock
    /// (dock-column-role-v1; an older daemon drops it). `pinned` makes it a pinned column in the
    /// same commit (Home's dock; `pinned-dock-alone-v1` lets a screen's only tab become it alone).
    static func toNewDockColumn(_ tab: TabModel, anchor pane: PaneModel, edge: CmuxNextLayout.DockEdge,
                                  mode: CmuxNextLayout.DockMode? = nil, role: CmuxNextLayout.DockRole? = nil,
                                  width: Double? = nil, respawn: SplitRespawn? = nil, pinned: Bool = false,
                                  services: AppServices,
                                  transaction: ClientTransactionID = .generate(), completion: @escaping Completion = { _ in }) {
        let daemon = services.machines.daemon(forTab: tab)
        guard services.daemon(for: pane) === daemon, daemon.supports(DaemonCapability.dockColumns.rawValue),
              !edge.isBand || daemon.supports(DaemonCapability.edgeDocks.rawValue),
              !refusesIncognitoCrossing(tab, to: pane, services: services) else { return completion(false) }
        let surface = tab.surface, paneHandle = pane.handle
        let overlay = mode.map { $0 == .overlay } ?? (DesignSettings.shared.dockColumnMode == .overlay)
        let pin = DockSnapshot(edge: DockSnapshot.Edge(rawValue: edge.rawValue) ?? .right, mode: overlay ? .overlay : .docked,
                               role: role.map { _ in .agentChat }, isPinned: pinned)
        // A band's size is a share of the screen height. A left dock (the agent chat dock) takes
        // half the window (cx-ihyx2, Lawrence 2026-10-14: "docked left columns needs to be 50% by
        // default"); a resize is the column's own width and stays. A right dock takes the width a
        // new column next to the anchor would take.
        let half = edge == .left && width == nil ? Self.leftDockWidth : nil
        let spawn = edge.isBand || width != nil || half != nil ? nil
            : services.newColumnWidth(nextTo: pane, movingFrom: services.locateTab(tab.id)?.1)
        let width = width ?? half ?? spawn?.width ?? 0.3
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
        let echoes = daemon.supports(DaemonCapability.tabDrag.rawValue)
        let before = Set(daemon.store.workspaces.compactMap(\.key))
        let name = newWorkspaceName(for: tab, services: services)
        // The daemon names the workspace in the move's commit when it can.
        let inCommit = daemon.supports(DaemonCapability.tabWorkspaceName.rawValue)
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
        // An agent chat's name is its chat's title, which only the turn store knows.
        let tabName = WorkspaceAutoNameWiring(services: services).reader.newWorkspaceName(tab)
        guard let sourceID = services.workspaceID(ofTab: tab.id), let source = services.workspace(id: sourceID),
              source.screens.flatMap(\.panes).flatMap(\.tabs).count == 1 else { return tabName }
        // The source workspace's own daemon, as WorkspaceAutoNameWiring reads it (none: legacy defaults apply).
        let daemon = services.machines.daemon(forWorkspace: sourceID)
        return NewWorkspaceName.forLastTab(workspaceName: source.name, workspaceTitle: source.title, tabName: tabName,
                                           workspaceNameSource: source.nameSource, workspaceNameRevision: source.nameRevision,
                                           allowsLegacyDefaults: !(daemon?.supports(DaemonCapability.workspaceNameSource.rawValue) ?? false))
    }

    /// What `NewWorkspaceName` reads from `tab`: the browser's live page
    /// title comes from the app's renderer, the rest from the store. An
    /// incognito page's title stays in memory (R102): the daemon stores the
    /// workspace name and keeps it in closed history.
    static func nameInput(_ tab: TabModel, services: AppServices) -> NewWorkspaceName.Tab {
        // A conversation, page or app tab's record is titled `about:blank`, a placeholder (a New
        // Tab page dragged to the sidebar named its workspace "about:blank"): only a name the tab
        // shows of its own names the workspace.
        if tab.kind == .conversation || tab.appTab != nil {
            return NewWorkspaceName.Tab(kind: .page, userName: tab.name, title: ownName(tab, services: services), pageTitle: nil, url: nil, cwd: nil)
        }
        let kind: NewWorkspaceName.Tab.Kind = switch tab.kind {
        case .pty: .terminal
        case .browser: .browser
        case .remoteTerminal: .remoteTerminal
        // A conversation or a kind this app does not know: its title still names it.
        case .conversation, .other: .terminal
        }
        let offTheRecord = tab.kind == .browser && services.cache.browserTabs.isIncognitoTab(tab.id) == true
        let pageTitle = tab.kind == .browser && !offTheRecord ? services.cache.existingBrowser(tab.id)?.tab.state.title : nil
        return NewWorkspaceName.Tab(kind: kind, userName: tab.name, title: tab.titleText, pageTitle: pageTitle,
                                    url: tab.url, cwd: tab.cwd)
    }

    /// The name a conversation, page or app tab shows of its own: its page's or app's title, its
    /// Home conversation's title or the Chief's name. Nil for an agent chat or New Tab page (named
    /// from its chat, `WorkspaceAutoNameReader`), an app with no page, and an untitled Home
    /// conversation: a generic label ("New Tab", "Home") written now would stay as the user's name.
    private static func ownName(_ tab: TabModel, services: AppServices) -> String? {
        if tab.agentSession != nil { return nil }
        if let app = tab.appTab {
            guard let provider = services.apps.pageProvider(appID: app.app, codeRouterAsPage: false) else { return nil }
            return services.pages.storeTabItem(tab, page: provider.page)?.title
        }
        if tab.page != nil { return services.pages.storeTabItem(tab)?.title }
        let title = services.home.tabTitle(for: tab)
        return title == HomeStrings.title ? nil : title
    }

    /// The other tabs of a multi-tab move follow the first into the workspace its move made (`key`), in order.
    static func join(_ tabs: ArraySlice<TabModel>, workspace key: WorkspaceKey, services: AppServices) async {
        guard let daemon = tabs.first.map(services.machines.daemon(forTab:)) else { return }
        if services.workspace(id: key.rawValue) == nil { await daemon.store.refresh() }
        guard let handle = services.workspace(id: key.rawValue)?.handle else { return }
        for surface in tabs.map(\.surface) { _ = await daemon.request("move-tab-to-workspace") { connection -> Void in _ = try await connection.moveTab(surface, toWorkspace: handle) } }
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
        let echoes = daemon.supports(DaemonCapability.tabDrag.rawValue)
        // Where the daemon appends the tab, shown now as an intent (tab-move-tearing); a workspace
        // with no pane yet waits for the daemon's layout.
        if let intent = daemon.store.workspaceMoveIntent(surface: surface, into: handle) {
            let send = daemon.intendNow("move-tab-to-workspace", intent, transaction: transaction) { connection -> Void in
                _ = try await connection.moveTab(surface, toWorkspace: handle, transaction: echoes ? transaction : nil)
            }
            services.registry.track(Task {
                let ok = await send() != nil
                completion(ok)
                return ok ? nil : "move-tab-to-workspace failed (see the app log)"
            })
            return
        }
        services.registry.track(Task {
            let ok = await daemon.request("move-tab-to-workspace") { connection -> Void in
                _ = try await connection.moveTab(surface, toWorkspace: handle, transaction: echoes ? transaction : nil)
            } != nil
            completion(ok)
            return ok ? nil : "move-tab-to-workspace failed (see the app log)"
        })
    }

    /// Workspaces never mix machines: says so and fails the move.
    static func refuseOtherMachine(_ services: AppServices, _ completion: Completion) {
        services.registry.refuse(TabDropStrings.otherMachine)
        completion(false)
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
