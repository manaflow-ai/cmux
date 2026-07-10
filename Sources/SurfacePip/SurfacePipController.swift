import AppKit
import Bonsplit
import CmuxTerminalCore

@MainActor
final class SurfacePipController {
    struct SnapshotEntry {
        let panelId: UUID
        let homeWorkspaceId: UUID
        let frame: NSRect
        let detached: Workspace.DetachedSurfaceTransfer
    }

    private struct Record {
        let panelId: UUID
        let homeWorkspaceId: UUID
        let homePaneId: PaneID?
        let homeIndex: Int?
        let detached: Workspace.DetachedSurfaceTransfer
        let windowController: SurfacePipWindowController
    }

    private weak var appDelegate: AppDelegate?
    private var recordsByPanelId: [UUID: Record] = [:]
    private var activePanelOrder: [UUID] = []
    private var lastFrame: NSRect?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    var activePanelIds: Set<UUID> {
        Set(recordsByPanelId.keys)
    }

    var hasActivePanels: Bool {
        !recordsByPanelId.isEmpty
    }

    var mostRecentActivePanelId: UUID? {
        activePanelOrder.reversed().first { recordsByPanelId[$0] != nil }
    }

    func canPopOut(panel: any Panel) -> Bool {
        guard !isInPip(panelId: panel.id) else { return false }
        switch panel.panelType {
        case .terminal, .browser:
            return true
        case .markdown, .filePreview, .rightSidebarTool, .customSidebar, .agentSession,
             .project, .extensionBrowser, .cloudVMLoading:
            return false
        }
    }

    func isInPip(panelId: UUID) -> Bool {
        recordsByPanelId[panelId] != nil
    }

    func panelId(for window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return recordsByPanelId.first { entry in
            entry.value.windowController.window === window
        }?.key
    }

    func snapshotsForSessionCapture() -> [SnapshotEntry] {
        recordsByPanelId.values.compactMap { record in
            guard let frame = record.windowController.window?.frame else { return nil }
            return SnapshotEntry(
                panelId: record.panelId,
                homeWorkspaceId: record.homeWorkspaceId,
                frame: frame,
                detached: record.detached
            )
        }
    }

    @discardableResult
    func toggleForCurrentContext() -> Bool {
        if let pipPanelId = panelId(for: NSApp.keyWindow) {
            return returnSurface(panelId: pipPanelId)
        }
        guard let appDelegate,
              let workspace = appDelegate.tabManager?.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            return false
        }
        return popOut(panelId: panelId, from: workspace)
    }

    @discardableResult
    func popOut(panelId: UUID, from workspace: Workspace) -> Bool {
        guard recordsByPanelId[panelId] == nil,
              let panel = workspace.panels[panelId],
              canPopOut(panel: panel) else {
            return false
        }

        let homePaneId = workspace.paneId(forPanelId: panelId)
        let homeIndex = workspace.indexInPane(forPanelId: panelId)
        guard let detached = workspace.detachSurface(panelId: panelId) else { return false }

        (detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.pictureInPicture)
        let hostPaneId = homePaneId ?? PaneID()
        let frame = nextFrame()
        let hostView = SurfacePipHostView(
            panel: detached.panel,
            workspaceId: workspace.id,
            paneId: hostPaneId,
            onRequestFocus: { [weak self] in
                self?.focusPipSurface(panelId: panelId)
            }
        )
        let windowController = SurfacePipWindowController(
            panelId: panelId,
            title: resolvedTitle(for: detached.panel),
            frame: frame,
            contentView: hostView,
            onRequestReturn: { [weak self] panelId in
                self?.returnSurface(panelId: panelId)
            }
        )
        recordsByPanelId[panelId] = Record(
            panelId: panelId,
            homeWorkspaceId: workspace.id,
            homePaneId: homePaneId,
            homeIndex: homeIndex,
            detached: detached,
            windowController: windowController
        )
        lastFrame = frame
        activePanelOrder.removeAll { $0 == panelId }
        activePanelOrder.append(panelId)
        windowController.show()
        focusPipSurface(panelId: panelId)
        return true
    }

    @discardableResult
    func returnSurface(panelId: UUID) -> Bool {
        guard let record = recordsByPanelId[panelId],
              let destination = destinationWorkspace(for: record) else {
            return false
        }

        (record.detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.workspace)
        guard destination.workspace.attachDetachedSurface(
            record.detached,
            inPane: destination.pane,
            atIndex: destination.index,
            focus: true
        ) != nil else {
            (record.detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.pictureInPicture)
            return false
        }

        recordsByPanelId.removeValue(forKey: panelId)
        activePanelOrder.removeAll { $0 == panelId }
        lastFrame = record.windowController.window?.frame ?? lastFrame
        record.windowController.closeForReturn()
        destination.tabManager.focusTab(destination.workspace.id, surfaceId: panelId, suppressFlash: true)
        focusPipReturnedSurface(panelId: panelId, workspaceId: destination.workspace.id)
        return true
    }

    private func focusPipSurface(panelId: UUID) {
        guard let record = recordsByPanelId[panelId] else { return }
        record.detached.panel.focus()
        FocusSurfaceBroadcaster.shared.emit(FocusSurfaceBroadcaster.FocusSurfacePayload(
            workspaceId: record.homeWorkspaceId,
            panelId: panelId,
            explicitFocusIntent: true
        ))
    }

    private func focusPipReturnedSurface(panelId: UUID, workspaceId: UUID) {
        FocusSurfaceBroadcaster.shared.emit(FocusSurfaceBroadcaster.FocusSurfacePayload(
            workspaceId: workspaceId,
            panelId: panelId,
            explicitFocusIntent: true
        ))
    }

    private func resolvedTitle(for panel: any Panel) -> String {
        let title = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return String(localized: "surfacePip.window.titleFallback", defaultValue: "Picture in Picture")
    }

    private func nextFrame() -> NSRect {
        let size = NSSize(width: 480, height: 320)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let base = lastFrame ?? NSRect(
            x: visibleFrame.maxX - size.width - 32,
            y: visibleFrame.minY + 32,
            width: size.width,
            height: size.height
        )
        var frame = base.offsetBy(dx: recordsByPanelId.isEmpty ? 0 : 24, dy: recordsByPanelId.isEmpty ? 0 : -24)
        if frame.minX < visibleFrame.minX || frame.maxX > visibleFrame.maxX ||
            frame.minY < visibleFrame.minY || frame.maxY > visibleFrame.maxY {
            frame.origin = NSPoint(
                x: visibleFrame.maxX - size.width - 32,
                y: visibleFrame.minY + 32
            )
            frame.size = size
        }
        return frame
    }

    private func destinationWorkspace(
        for record: Record
    ) -> (tabManager: TabManager, workspace: Workspace, pane: PaneID, index: Int?)? {
        if let home = workspace(id: record.homeWorkspaceId) {
            let pane = record.homePaneId.flatMap { pane in
                home.workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
            } ?? home.workspace.bonsplitController.focusedPaneId
                ?? home.workspace.bonsplitController.allPaneIds.first
            if let pane {
                return (home.tabManager, home.workspace, pane, record.homeIndex)
            }
        }

        if let focused = focusedWorkspaceFallback() {
            let pane = focused.workspace.bonsplitController.focusedPaneId
                ?? focused.workspace.bonsplitController.allPaneIds.first
            if let pane {
                return (focused.tabManager, focused.workspace, pane, nil)
            }
        }

        return newWorkspaceFallback()
    }

    private func workspace(id: UUID) -> (tabManager: TabManager, workspace: Workspace)? {
        guard let appDelegate,
              let manager = appDelegate.tabManagerFor(tabId: id),
              let workspace = manager.tabs.first(where: { $0.id == id }) else {
            return nil
        }
        return (manager, workspace)
    }

    private func focusedWorkspaceFallback() -> (tabManager: TabManager, workspace: Workspace)? {
        guard let appDelegate else { return nil }
        if let manager = appDelegate.tabManager,
           let workspace = manager.selectedWorkspace ?? manager.tabs.first {
            return (manager, workspace)
        }
        for context in appDelegate.mainWindowContexts.values {
            if let workspace = context.tabManager.selectedWorkspace ?? context.tabManager.tabs.first {
                return (context.tabManager, workspace)
            }
        }
        return nil
    }

    private func newWorkspaceFallback() -> (tabManager: TabManager, workspace: Workspace, pane: PaneID, index: Int?)? {
        guard let appDelegate else { return nil }
        let manager: TabManager
        if let existing = appDelegate.tabManager ?? appDelegate.mainWindowContexts.values.first?.tabManager {
            manager = existing
        } else {
            let windowId = appDelegate.createMainWindow(shouldActivate: false)
            guard let context = appDelegate.mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
                return nil
            }
            manager = context.tabManager
        }
        let workspace = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        guard let pane = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }
        return (manager, workspace, pane, nil)
    }
}
