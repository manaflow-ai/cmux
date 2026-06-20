import Foundation
import AppKit
import Bonsplit

@MainActor
private enum CmuxSelectionEventState {
    static var selectedSurfaceByWorkspacePane: [String: UUID] = [:]
    static var focusedPaneByWorkspace: [UUID: UUID] = [:]
    static var focusedSurfaceByWorkspace: [UUID: UUID] = [:]

    static func paneKey(workspaceId: UUID, paneId: UUID) -> String {
        "\(workspaceId.uuidString):\(paneId.uuidString)"
    }

    static func clearWorkspace(_ workspaceId: UUID) {
        selectedSurfaceByWorkspacePane = selectedSurfaceByWorkspacePane.filter {
            !$0.key.hasPrefix("\(workspaceId.uuidString):")
        }
        focusedPaneByWorkspace.removeValue(forKey: workspaceId)
        focusedSurfaceByWorkspace.removeValue(forKey: workspaceId)
    }

    static func clearPane(workspaceId: UUID, paneId: UUID) {
        selectedSurfaceByWorkspacePane.removeValue(forKey: paneKey(workspaceId: workspaceId, paneId: paneId))
        if focusedPaneByWorkspace[workspaceId] == paneId {
            focusedPaneByWorkspace.removeValue(forKey: workspaceId)
        }
    }

    static func clearSurface(workspaceId: UUID, surfaceId: UUID) {
        selectedSurfaceByWorkspacePane = selectedSurfaceByWorkspacePane.filter { $0.value != surfaceId }
        if focusedSurfaceByWorkspace[workspaceId] == surfaceId {
            focusedSurfaceByWorkspace.removeValue(forKey: workspaceId)
        }
    }
}

extension TabManager {
    func publishCmuxWorkspaceCreated(_ workspace: Workspace, selected: Bool) {
        CmuxEventBus.shared.publishWorkspaceCreated(
            workspaceId: workspace.id,
            title: workspace.cmuxEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            selected: selected,
            index: tabs.firstIndex(where: { $0.id == workspace.id }),
            tabCount: tabs.count
        )
    }

    func publishCmuxInitialSurfaceCreated(_ workspace: Workspace, selected: Bool) {
        guard let panelId = workspace.focusedSurfaceId,
              let panel = workspace.panels[panelId] else { return }
        workspace.publishCmuxSurfaceCreated(
            panelId,
            paneId: workspace.paneId(forPanelId: panelId),
            kind: Workspace.cmuxEventSurfaceKind(panel),
            origin: "workspace_initial",
            focused: selected
        )
    }

    func publishCmuxWorkspaceClosed(_ workspace: Workspace) {
        CmuxEventBus.shared.publishWorkspaceClosed(
            workspaceId: workspace.id,
            title: workspace.cmuxEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            remainingTabCount: tabs.count
        )
        CmuxSelectionEventState.clearWorkspace(workspace.id)
    }

    func publishCmuxWorkspaceSelected(_ workspace: Workspace) {
        CmuxEventBus.shared.publishWorkspaceSelected(
            workspaceId: workspace.id,
            title: workspace.cmuxEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            previousWorkspaceId: nil,
            index: tabs.firstIndex(where: { $0.id == workspace.id }),
            tabCount: tabs.count
        )
    }

    func publishCmuxWorkspaceSelectedChange(from previousWorkspaceId: UUID?) {
        guard let selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedTabId }) else { return }
        CmuxEventBus.shared.publishWorkspaceSelected(
            workspaceId: workspace.id,
            title: workspace.cmuxEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            previousWorkspaceId: previousWorkspaceId,
            index: tabs.firstIndex(where: { $0.id == workspace.id }),
            tabCount: tabs.count
        )
    }
}

extension Workspace {
    var cmuxEventWorkspaceTitle: String {
        customTitle ?? title
    }

    func publishCmuxSplitCreated(
        _ paneId: PaneID,
        sourcePaneId: PaneID?,
        orientation: SplitOrientation,
        surfaceId: UUID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {
        CmuxEventBus.shared.publishPaneCreated(
            workspaceId: id,
            paneId: paneId.id,
            sourcePaneId: sourcePaneId?.id,
            orientation: orientation.rawValue,
            surfaceId: surfaceId,
            origin: origin
        )
        if let surfaceId {
            publishCmuxSurfaceCreated(surfaceId, paneId: paneId, kind: kind, origin: origin, focused: focused)
        }
    }

    func publishCmuxSurfaceCreated(
        _ surfaceId: UUID,
        paneId: PaneID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {
        CmuxEventBus.shared.publishSurfaceCreated(
            workspaceId: id,
            surfaceId: surfaceId,
            paneId: paneId?.id,
            kind: kind,
            origin: origin,
            focused: focused
        )
    }

    func publishCmuxSurfaceClosed(_ surfaceId: UUID, paneId: PaneID?, panel: (any Panel)?, origin: String) {
        CmuxEventBus.shared.publishSurfaceClosed(
            workspaceId: id,
            surfaceId: surfaceId,
            paneId: paneId?.id,
            kind: panel.map(Self.cmuxEventSurfaceKind),
            origin: origin
        )
        CmuxSelectionEventState.clearSurface(workspaceId: id, surfaceId: surfaceId)
    }

    func publishCmuxPaneClosed(_ paneId: PaneID, closedPanelIds: [UUID], origin: String) {
        CmuxEventBus.shared.publishPaneClosed(
            workspaceId: id,
            paneId: paneId.id,
            closedSurfaceIds: closedPanelIds,
            origin: origin
        )
        CmuxSelectionEventState.clearPane(workspaceId: id, paneId: paneId.id)
    }

    func publishCmuxFocusedSelection(paneId: PaneID, surfaceId: UUID, origin: String) {
        let paneKey = CmuxSelectionEventState.paneKey(workspaceId: id, paneId: paneId.id)
        let previousSelectedSurfaceId = CmuxSelectionEventState.selectedSurfaceByWorkspacePane[paneKey]
        let kind = panels[surfaceId].map(Self.cmuxEventSurfaceKind)

        if previousSelectedSurfaceId != surfaceId {
            CmuxSelectionEventState.selectedSurfaceByWorkspacePane[paneKey] = surfaceId
            CmuxEventBus.shared.publishSurfaceSelected(
                workspaceId: id,
                surfaceId: surfaceId,
                paneId: paneId.id,
                kind: kind,
                previousSurfaceId: previousSelectedSurfaceId,
                focused: true,
                origin: origin
            )
        }

        if CmuxSelectionEventState.focusedPaneByWorkspace[id] != paneId.id {
            CmuxSelectionEventState.focusedPaneByWorkspace[id] = paneId.id
            CmuxEventBus.shared.publishPaneFocused(
                workspaceId: id,
                paneId: paneId.id,
                selectedSurfaceId: surfaceId,
                origin: origin
            )
        }

        if CmuxSelectionEventState.focusedSurfaceByWorkspace[id] != surfaceId {
            CmuxSelectionEventState.focusedSurfaceByWorkspace[id] = surfaceId
            CmuxEventBus.shared.publishSurfaceFocused(
                workspaceId: id,
                surfaceId: surfaceId,
                paneId: paneId.id,
                kind: kind,
                origin: origin
            )
        }
    }

    static func cmuxEventSurfaceKind(_ panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return "terminal"
        case .browser:
            return "browser"
        case .markdown:
            return "markdown"
        case .filePreview:
            return "file_preview"
        case .rightSidebarTool:
            return "right_sidebar_tool"
        case .customSidebar:
            return "custom_sidebar"
        case .agentSession:
            return "agent_session"
        case .project:
            return "project"
        case .extensionBrowser:
            return "extension_browser"
        }
    }
}

@MainActor
private enum MainWindowKeyRegainRefresh {
    static func refresh(window: NSWindow, context: AppDelegate.MainWindowContext) {
        // Window focus regain owns the redraw invariant. Cursor tracking and
        // focused subviews can update themselves only after this invalidation.
        invalidateContentDisplayTree(window: window)
        _ = context.keyboardFocusCoordinator.restoreTargetAfterWindowBecameKey()
    }

    private static func invalidateContentDisplayTree(window: NSWindow) {
        guard let contentView = window.contentView else { return }
        invalidateDisplayTree(rootedAt: contentView)
        window.invalidateCursorRects(for: contentView)
    }

    private static func invalidateDisplayTree(rootedAt view: NSView) {
        guard !view.isHidden else { return }
        view.needsDisplay = true
        view.layer?.setNeedsDisplay()
        for subview in view.subviews {
            invalidateDisplayTree(rootedAt: subview)
        }
    }
}

extension AppDelegate {
    func handleCmuxWindowBecameKey(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        MainActor.assumeIsolated {
            let context = contextForMainTerminalWindow(window)
            setActiveMainWindow(window)
            if let windowId = mainWindowId(from: window) {
                publishCmuxWindowLifecycle(name: "window.keyed", windowId: windowId, origin: "appkit_key")
            }
            if let context {
                MainWindowKeyRegainRefresh.refresh(window: window, context: context)
            }
        }
    }

    func handleCmuxWindowResignedKey(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        MainActor.assumeIsolated {
            if let windowId = mainWindowId(from: window) {
                publishCmuxWindowLifecycle(name: "window.unkeyed", windowId: windowId, origin: "appkit_key")
            }
        }
    }

    func publishCmuxWindowLifecycle(name: String, windowId: UUID, origin: String) {
        let manager = tabManagerFor(windowId: windowId)
        let workspaceId = manager?.selectedTabId
        let selectedWorkspaceIndex = workspaceId.flatMap { selectedId in
            manager?.tabs.firstIndex(where: { $0.id == selectedId })
        }
        let window = mainWindow(for: windowId)
        CmuxEventBus.shared.publishWindowLifecycle(
            name: name,
            windowId: windowId,
            workspaceId: workspaceId,
            workspaceCount: manager?.tabs.count,
            selectedWorkspaceIndex: selectedWorkspaceIndex,
            isKeyWindow: window?.isKeyWindow,
            isMainWindow: window?.isMainWindow,
            origin: origin
        )
    }
}
