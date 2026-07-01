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

    /// Creates a surface (tab) in the routed window's right-sidebar Dock. The
    /// Dock hosts terminal and browser surfaces only; agent-session is unsupported.
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
        guard let app = AppDelegate.shared,
              let dock = app.windowDock(for: tabManager) else {
            return .workspaceNotFound
        }
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

    func dockReferenceWindowId(app: AppDelegate, tabManager: TabManager) -> UUID? {
        app.windowId(for: tabManager) ?? v2ResolveWindowId(tabManager: tabManager)
    }

    func windowDockContainingPanel(_ surfaceId: UUID) -> DockSplitStore? {
        AppDelegate.shared?.windowDockContainingPanel(surfaceId)
    }

    func windowDockContainingPane(_ paneId: UUID) -> DockSplitStore? {
        AppDelegate.shared?.windowDockContainingPane(paneId)
    }

    /// The window Dock a command routes to, if any: an explicit dock-owner
    /// `workspace_id` (or the legacy alias, resolved against `tabManager`'s
    /// window), else the Dock containing the routed surface or pane.
    ///
    /// An explicit `window_id` must agree with the Dock's owning window —
    /// disagreement returns `nil` so the caller fails closed rather than acting
    /// on a Dock the caller did not name. (The alias agrees by construction:
    /// an explicit `window_id` already selected `tabManager`.) An explicit
    /// owner id likewise wins over surface/pane containment; a mismatched
    /// routed surface/pane then fails the downstream `containsPanel`/
    /// `containsPane` guards.
    func windowDockForRouting(_ routing: ControlRoutingSelectors, tabManager: TabManager) -> DockSplitStore? {
        func matchesRequestedWindow(_ dock: DockSplitStore) -> Bool {
            guard routing.hasWindowIDParam, let requestedWindowID = routing.windowID else { return true }
            return dock.workspaceId == requestedWindowID
        }
        if let workspaceID = routing.workspaceID {
            if workspaceID == AppDelegate.windowDockAliasWorkspaceId {
                return AppDelegate.shared?.windowDock(for: tabManager)
            }
            if let dock = AppDelegate.shared?.existingWindowDock(forWindowId: workspaceID) {
                return matchesRequestedWindow(dock) ? dock : nil
            }
        }
        if let surfaceID = routing.surfaceID,
           let dock = windowDockContainingPanel(surfaceID) {
            return matchesRequestedWindow(dock) ? dock : nil
        }
        if let paneID = routing.paneID,
           let dock = windowDockContainingPane(paneID) {
            return matchesRequestedWindow(dock) ? dock : nil
        }
        return nil
    }

    /// The window id Dock-scoped results report and Dock-scoped focus targets.
    /// A window Dock's owner id IS its window id, and the registry is the single
    /// source of truth for which window renders a Dock surface — the routed
    /// `tabManager` can be a different window when the caller's context
    /// (injected workspace/window selectors) disagrees with the surface's home.
    func dockResultWindowId(for dock: DockSplitStore, tabManager: TabManager) -> UUID? {
        dock.scope == .global ? dock.workspaceId : v2ResolveWindowId(tabManager: tabManager)
    }

    /// The `TabManager` Dock-scoped focus/reveal should act on: the Dock's
    /// owning window. Falls back to the routed manager only for workspace Docks
    /// (whose reveal semantics are unchanged) — see `dockResultWindowId`.
    func dockOwnerTabManager(for dock: DockSplitStore, fallback: TabManager) -> TabManager {
        guard dock.scope == .global else { return fallback }
        return AppDelegate.shared?.tabManagerFor(windowId: dock.workspaceId) ?? fallback
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
        // A dock-routing workspace_id never reaches here: controlSurfaceClose
        // handles it through windowDockForRouting before resolving a workspace.
        return fallbackWorkspace.focusedPanelId
    }

    func resolvedWindowDockSurfaceId(
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
        let resolved = resolvedWindowDockSurfaceId(
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
        // Indexed path: only workspaces/windows that actually have a Dock
        // register a live store, so this asks each store's authoritative
        // `containsPanel` instead of walking every window × workspace tab.
        // Falls through to the scan if a store can't be located.
        for store in DockSplitStore.liveStores where store.containsPanel(surfaceId) {
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
        for store in DockSplitStore.liveStores where store.containsPane(paneId) {
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
        if store.scope == .global {
            // Window Dock: its owner id IS the owning window's id.
            let windowId = store.workspaceId
            guard let tabManager = app.tabManagerFor(windowId: windowId) else { return nil }
            return (windowId, store.workspaceId, tabManager, tabManager.selectedWorkspace ?? tabManager.tabs.first)
        }
        guard let tabManager = app.tabManagerFor(tabId: store.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == store.workspaceId }),
              let windowId = dockReferenceWindowId(app: app, tabManager: tabManager) else { return nil }
        return (windowId, store.workspaceId, tabManager, workspace)
    }
}
