import Foundation
import AppKit
import Bonsplit

nonisolated struct CmuxSurfaceFrameSnapshot: Equatable, Sendable {
    let frame: CGRect
    let screen: String?
    let inWindow: Bool

    var framePayload: [String: Double] {
        Self.rectPayload(frame)
    }

    var boundsPayload: [String: Double] {
        [
            "x": 0,
            "y": 0,
            "width": Double(frame.width),
            "height": Double(frame.height)
        ]
    }

    var screenPayload: String? {
        screen
    }

    static func rectPayload(_ rect: CGRect) -> [String: Double] {
        [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.size.width),
            "height": Double(rect.size.height)
        ]
    }

    static func appendPayloadFields(
        to item: inout [String: Any],
        snapshot: CmuxSurfaceFrameSnapshot?
    ) {
        guard let snapshot else {
            item["frame"] = NSNull()
            item["bounds"] = NSNull()
            item["screen"] = NSNull()
            item["in_window"] = false
            return
        }

        item["frame"] = snapshot.framePayload
        item["bounds"] = snapshot.boundsPayload
        item["screen"] = snapshot.screenPayload ?? NSNull()
        item["in_window"] = snapshot.inWindow
    }
}

@MainActor
enum CmuxSurfaceFrameSnapshotResolver {
    static func snapshotsBySurfaceId(
        in workspace: Workspace,
        layoutSnapshot: LayoutSnapshot? = nil,
        window explicitWindow: NSWindow? = nil
    ) -> [UUID: CmuxSurfaceFrameSnapshot] {
        let windowState = AppDelegate.shared?.scriptableMainWindowForTab(workspace.id)
        guard windowState?.tabManager.selectedTabId == workspace.id else { return [:] }
        guard let window = explicitWindow ?? windowState?.window,
              let contentView = window.contentView else { return [:] }

        let layout = layoutSnapshot ?? workspace.bonsplitController.layoutSnapshot()
        var snapshots: [UUID: CmuxSurfaceFrameSnapshot] = [:]

        for panel in workspace.panels.values {
            let paneId = workspace.paneId(forPanelId: panel.id)
            let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layout,
                paneId: paneId
            )
            let exactRect = ContentView.tmuxWorkspacePaneExactRect(
                for: panel,
                in: contentView
            )
            guard let contentRect = ContentView.preferredTmuxWorkspacePaneWindowOverlayRect(
                exactRect: exactRect,
                paneRect: paneRect
            ),
            let snapshot = snapshot(
                contentRect: contentRect,
                contentView: contentView,
                window: window
            ) else {
                continue
            }
            snapshots[panel.id] = snapshot
        }

        return snapshots
    }

    private static func snapshot(
        contentRect: CGRect,
        contentView: NSView,
        window fallbackWindow: NSWindow
    ) -> CmuxSurfaceFrameSnapshot? {
        guard contentRect.width > 1, contentRect.height > 1 else { return nil }
        let window = contentView.window ?? fallbackWindow
        let rectInWindow = contentView.convert(contentRect, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        guard rectInScreen.width > 1, rectInScreen.height > 1 else { return nil }

        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(rectInScreen) })
        let screenId = screen?.cmuxDisplayID.map { "screen:\($0)" }
        return CmuxSurfaceFrameSnapshot(
            frame: rectInScreen,
            screen: screenId,
            inWindow: contentView.window != nil && window.isVisible
        )
    }
}

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

@MainActor
private enum CmuxSurfaceFrameEventState {
    static var frameByWorkspaceSurface: [String: CmuxSurfaceFrameSnapshot] = [:]

    static func surfaceKey(workspaceId: UUID, surfaceId: UUID) -> String {
        "\(workspaceId.uuidString):\(surfaceId.uuidString)"
    }

    static func clearWorkspace(_ workspaceId: UUID) {
        frameByWorkspaceSurface = frameByWorkspaceSurface.filter {
            !$0.key.hasPrefix("\(workspaceId.uuidString):")
        }
    }

    static func clearSurface(workspaceId: UUID, surfaceId: UUID) {
        frameByWorkspaceSurface.removeValue(
            forKey: surfaceKey(workspaceId: workspaceId, surfaceId: surfaceId)
        )
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
        guard let terminalPanel = workspace.focusedTerminalPanel else { return }
        workspace.publishCmuxSurfaceCreated(
            terminalPanel.id,
            paneId: workspace.paneId(forPanelId: terminalPanel.id),
            kind: "terminal",
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
        CmuxSurfaceFrameEventState.clearWorkspace(workspace.id)
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
        publishCmuxSelectedWorkspaceSurfaceFrameChanges(workspace)
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
        publishCmuxSelectedWorkspaceSurfaceFrameChanges(workspace)
    }

    private func publishCmuxSelectedWorkspaceSurfaceFrameChanges(_ workspace: Workspace) {
        DispatchQueue.main.async { [weak workspace] in
            workspace?.publishCmuxSurfaceFrameChanges(origin: "workspace_selected")
        }
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
        publishCmuxSurfaceFrameChanges(origin: "\(origin).surface_created")
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
        CmuxSurfaceFrameEventState.clearSurface(workspaceId: id, surfaceId: surfaceId)
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

    func publishCmuxSurfaceFrameChanges(
        layoutSnapshot: LayoutSnapshot? = nil,
        origin: String
    ) {
        let snapshots = CmuxSurfaceFrameSnapshotResolver.snapshotsBySurfaceId(
            in: self,
            layoutSnapshot: layoutSnapshot
        )
        guard !snapshots.isEmpty else { return }

        for (surfaceId, snapshot) in snapshots {
            let key = CmuxSurfaceFrameEventState.surfaceKey(
                workspaceId: id,
                surfaceId: surfaceId
            )
            guard CmuxSurfaceFrameEventState.frameByWorkspaceSurface[key] != snapshot else {
                continue
            }
            CmuxSurfaceFrameEventState.frameByWorkspaceSurface[key] = snapshot
            let paneId = paneId(forPanelId: surfaceId)
            CmuxEventBus.shared.publishSurfaceFrameChanged(
                workspaceId: id,
                surfaceId: surfaceId,
                paneId: paneId?.id,
                kind: panels[surfaceId].map(Self.cmuxEventSurfaceKind),
                snapshot: snapshot,
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
