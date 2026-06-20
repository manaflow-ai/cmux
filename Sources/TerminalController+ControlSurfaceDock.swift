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

    /// Creates a surface (tab) in the workspace's right-sidebar Dock. The Dock
    /// hosts terminal and browser surfaces only; agent-session is unsupported.
    func dockSurfaceCreate(
        ws: Workspace,
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
        let dock = ws.dockSplit
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
            workspaceID: ws.id,
            dockPaneID: paneId.id,
            dockSurfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }

    func resolveSurfaceCreateWorkspace(
        placement: ControlPlacementResolution,
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        requestedPaneID: UUID?
    ) -> Workspace? {
        if case .dock = placement,
           routing.workspaceID == nil,
           routing.surfaceID == nil,
           let requestedPaneID,
           let dockWorkspace = tabManager.tabs.first(where: { $0.containsDockPane(requestedPaneID) }) {
            return dockWorkspace
        }
        return resolveSurfaceWorkspace(routing: routing, tabManager: tabManager)
    }

    func locateDockSurface(_ surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId),
                  let workspace = manager.tabs.first(where: { $0.containsDockPanel(surfaceId) }) else { continue }
            return (summary.windowId, workspace.id, manager)
        }
        return nil
    }

    func locateDockPane(_ paneId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager, workspace: Workspace)? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId),
                  let workspace = manager.tabs.first(where: { $0.containsDockPane(paneId) }) else { continue }
            return (summary.windowId, workspace.id, manager, workspace)
        }
        return nil
    }
}
