import AppKit
import CmuxControlSocket
import Foundation

extension TerminalController {
    @discardableResult
    func revealDockForFocus(tabManager: TabManager) -> Bool {
        let preferredWindow = v2ResolveWindowId(tabManager: tabManager)
            .flatMap { AppDelegate.shared?.mainWindow(for: $0) }
        return AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .dock,
            focusFirstItem: false,
            preferredWindow: preferredWindow
        ) ?? false
    }

    func dockUnsupportedSurfaceTypeMessage() -> String {
        String(localized: "dock.error.unsupportedSurfaceType", defaultValue: "Dock placement supports only terminal and browser surfaces")
    }

    func dockUnavailableMessage() -> String {
        String(localized: "dock.error.unavailable", defaultValue: "Dock placement is disabled")
    }

    /// Creates a surface (tab) in the app-wide right-sidebar Dock. The Dock
    /// hosts terminal and browser surfaces only; agent-session is unsupported.
    func dockSurfaceCreate(
        tabManager: TabManager,
        panelType: PanelType,
        url: URL?,
        inputs: ControlSurfaceCreateInputs
    ) -> ControlSurfaceCreateResolution {
        guard panelType == .terminal || panelType == .browser else {
            return .dockUnsupportedType(typeRawValue: panelType.rawValue, message: dockUnsupportedSurfaceTypeMessage())
        }
        guard RightSidebarMode.dock.isAvailable() else {
            return .dockUnavailable(message: dockUnavailableMessage())
        }
        guard let app = AppDelegate.shared else {
            return .workspaceNotFound
        }
        let dock = app.globalDock
        guard let paneId = dock.resolvePane(requestedPaneID: inputs.requestedPaneID) else {
            return .paneNotFound
        }
        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        let kind: DockSurfaceKind = (panelType == .browser) ? .browser : .terminal
        if focus {
            revealDockForFocus(tabManager: tabManager)
        }
        let newPanelId = dock.newSurface(
            kind: kind,
            inPane: paneId,
            url: kind == .browser ? url : nil,
            command: kind == .terminal ? inputs.initialCommand : nil,
            workingDirectory: kind == .terminal ? inputs.workingDirectory : nil,
            environment: inputs.startupEnvironment,
            tmuxStartCommand: kind == .terminal ? inputs.tmuxStartCommand : nil,
            focus: focus
        )
        guard let newPanelId else {
            return .createFailed
        }
        return .createdDock(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: dock.workspaceId,
            dockPaneID: paneId.id,
            dockSurfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }

    func resolveSurfaceCreateWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        return resolveSurfaceWorkspace(routing: routing, tabManager: tabManager)
    }

    func globalDockContextWorkspace(tabManager: TabManager) -> Workspace? {
        tabManager.selectedWorkspace ?? tabManager.tabs.first
    }

    func dockReferenceWindowId(app: AppDelegate, tabManager: TabManager) -> UUID? {
        app.windowId(for: tabManager) ?? v2ResolveWindowId(tabManager: tabManager)
    }

    func globalDockContainingPanel(_ surfaceId: UUID) -> DockSplitStore? {
        guard let dock = AppDelegate.shared?.existingGlobalDock,
              dock.containsPanel(surfaceId) else { return nil }
        return dock
    }

    func globalDockContainingPane(_ paneId: UUID) -> DockSplitStore? {
        guard let dock = AppDelegate.shared?.existingGlobalDock,
              dock.containsPane(paneId) else { return nil }
        return dock
    }

    func globalDockForRouting(_ routing: ControlRoutingSelectors) -> DockSplitStore? {
        if let workspaceID = routing.workspaceID,
           AppDelegate.isGlobalDockOwnerId(workspaceID) {
            return AppDelegate.shared?.globalDock
        }
        if let surfaceID = routing.surfaceID,
           let dock = globalDockContainingPanel(surfaceID) {
            return dock
        }
        if let paneID = routing.paneID,
           let dock = globalDockContainingPane(paneID) {
            return dock
        }
        return nil
    }

    func orderedPanels(in dock: DockSplitStore) -> [any Panel] {
        var seenPanelIds: Set<UUID> = []
        var ordered: [any Panel] = []
        for tabId in dock.bonsplitController.allTabIds {
            guard let panel = dock.panel(for: tabId),
                  seenPanelIds.insert(panel.id).inserted else { continue }
            ordered.append(panel)
        }
        return ordered
    }

    func dockPanelTitle(_ panel: any Panel, in dock: DockSplitStore) -> String {
        guard let tabId = dock.surfaceId(forPanelId: panel.id),
              let paneId = dock.paneId(forPanelId: panel.id),
              let tab = dock.bonsplitController.tabs(inPane: paneId).first(where: { $0.id == tabId }) else {
            return panel.displayTitle
        }
        return tab.title
    }

    func resolvedSurfaceIdForClose(
        explicitSurfaceID: UUID?,
        routing: ControlRoutingSelectors,
        fallbackWorkspace: Workspace
    ) -> UUID? {
        if let explicitSurfaceID {
            return explicitSurfaceID
        }
        if let routedSurfaceID = routing.surfaceID {
            return routedSurfaceID
        }
        if let workspaceID = routing.workspaceID,
           AppDelegate.isGlobalDockOwnerId(workspaceID) {
            return AppDelegate.shared?.existingGlobalDock?.focusedPanelId
        }
        return fallbackWorkspace.focusedPanelId
    }

    func resolvedGlobalDockSurfaceId(
        explicitSurfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        routing: ControlRoutingSelectors,
        dock: DockSplitStore
    ) -> (surfaceID: UUID?, invalidSurfaceID: Bool) {
        if hasSurfaceIDParam && explicitSurfaceID == nil {
            return (nil, true)
        }
        if let explicitSurfaceID {
            return (explicitSurfaceID, false)
        }
        if let routedSurfaceID = routing.surfaceID {
            return (routedSurfaceID, false)
        }
        return (dock.focusedPanelId, false)
    }

    func terminalPanel(
        in dock: DockSplitStore,
        explicitSurfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        routing: ControlRoutingSelectors
    ) -> (surfaceID: UUID?, terminalPanel: TerminalPanel?, invalidSurfaceID: Bool) {
        let resolved = resolvedGlobalDockSurfaceId(
            explicitSurfaceID: explicitSurfaceID,
            hasSurfaceIDParam: hasSurfaceIDParam,
            routing: routing,
            dock: dock
        )
        guard let surfaceID = resolved.surfaceID else {
            return (nil, nil, resolved.invalidSurfaceID)
        }
        return (surfaceID, dock.panels[surfaceID] as? TerminalPanel, false)
    }

    func locateDockSurface(_ surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        guard let app = AppDelegate.shared else { return nil }
        if let globalDock = app.existingGlobalDock,
           globalDock.containsPanel(surfaceId),
           let tabManager = app.dockReferenceTabManager(for: globalDock),
           let windowId = dockReferenceWindowId(app: app, tabManager: tabManager) {
            return (
                windowId,
                globalDock.workspaceId,
                tabManager
            )
        }
        // Indexed path: only workspaces that actually have a Dock register a live
        // store, so this asks each store's authoritative `containsPanel` instead
        // of walking every window × workspace tab. The global store is already
        // handled above. Falls through to the scan if a store can't be located.
        for store in DockSplitStore.liveStores
        where !AppDelegate.isGlobalDockOwnerId(store.workspaceId) && store.containsPanel(surfaceId) {
            if let location = dockStoreLocation(store, app: app) {
                return (location.windowId, location.workspaceId, location.tabManager)
            }
        }
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId),
                  let workspace = manager.tabs.first(where: { $0.containsDockPanel(surfaceId) }) else { continue }
            return (summary.windowId, workspace.id, manager)
        }
        return nil
    }

    func locateDockPane(_ paneId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager, workspace: Workspace)? {
        guard let app = AppDelegate.shared else { return nil }
        if let globalDock = app.existingGlobalDock,
           globalDock.containsPane(paneId),
           let tabManager = app.dockReferenceTabManager(for: globalDock),
           let windowId = dockReferenceWindowId(app: app, tabManager: tabManager),
           let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first {
            return (
                windowId,
                globalDock.workspaceId,
                tabManager,
                workspace
            )
        }
        for store in DockSplitStore.liveStores
        where !AppDelegate.isGlobalDockOwnerId(store.workspaceId) && store.containsPane(paneId) {
            if let location = dockStoreLocation(store, app: app), let workspace = location.workspace {
                return (location.windowId, location.workspaceId, location.tabManager, workspace)
            }
        }
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId),
                  let workspace = manager.tabs.first(where: { $0.containsDockPane(paneId) }) else { continue }
            return (summary.windowId, workspace.id, manager, workspace)
        }
        return nil
    }

    /// Resolves the owning window, workspace id, tab manager, and (for
    /// per-workspace Docks) the `Workspace` for a live Dock `store`. Used by the
    /// indexed `locateDockSurface` / `locateDockPane` paths.
    private func dockStoreLocation(
        _ store: DockSplitStore,
        app: AppDelegate
    ) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager, workspace: Workspace?)? {
        if AppDelegate.isGlobalDockOwnerId(store.workspaceId) {
            guard let tabManager = app.dockReferenceTabManager(for: store),
                  let windowId = dockReferenceWindowId(app: app, tabManager: tabManager) else { return nil }
            return (windowId, store.workspaceId, tabManager, tabManager.selectedWorkspace ?? tabManager.tabs.first)
        }
        guard let tabManager = app.tabManagerFor(tabId: store.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == store.workspaceId }),
              let windowId = dockReferenceWindowId(app: app, tabManager: tabManager) else { return nil }
        return (windowId, store.workspaceId, tabManager, workspace)
    }
}
