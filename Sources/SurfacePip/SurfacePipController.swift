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
        let hostingWindowId: UUID
        let detached: Workspace.DetachedSurfaceTransfer
        let overlayController: SurfacePipOverlayController
    }

    private weak var appDelegate: AppDelegate?
    private var recordsByPanelId: [UUID: Record] = [:]
    private var activePanelOrder: [UUID] = []
    private var focusedPanelId: UUID?
    private var lastFrame: NSRect?
    private var lastCorner: SurfacePipOverlayController.Corner = .bottomTrailing
    private var focusObserver: NSObjectProtocol?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        focusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleFocusSurfaceNotification(notification)
            }
        }
    }

    deinit {
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
        }
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
        guard let window,
              window.isKeyWindow,
              let panelId = focusedPanelId,
              let record = recordsByPanelId[panelId],
              let appDelegate,
              appDelegate.mainWindowId(from: window) == record.hostingWindowId,
              firstResponderBelongs(to: record, in: window) else {
            return nil
        }
        return panelId
    }

    private func firstResponderBelongs(to record: Record, in window: NSWindow) -> Bool {
        guard let responderView = window.firstResponder as? NSView else { return false }
        if responderView === record.overlayController.containerView ||
            responderView.isDescendant(of: record.overlayController.containerView) {
            return true
        }
        if let terminalPanel = record.detached.panel as? TerminalPanel {
            return responderView === terminalPanel.hostedView ||
                responderView.isDescendant(of: terminalPanel.hostedView)
        }
        if let browserPanel = record.detached.panel as? BrowserPanel {
            return responderView === browserPanel.webView ||
                responderView.isDescendant(of: browserPanel.webView)
        }
        return false
    }

    func snapshotsForSessionCapture() -> [SnapshotEntry] {
        recordsByPanelId.values.compactMap { record in
            return SnapshotEntry(
                panelId: record.panelId,
                homeWorkspaceId: record.homeWorkspaceId,
                frame: record.overlayController.windowRelativeFrame,
                detached: record.detached
            )
        }
    }

    @discardableResult
    func toggleForCurrentContext(tabManager: TabManager?) -> Bool {
        if let pipPanelId = panelId(for: NSApp.keyWindow ?? NSApp.mainWindow) {
            return returnSurface(panelId: pipPanelId)
        }
        if let workspace = tabManager?.selectedWorkspace,
           let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId],
           canPopOut(panel: panel) {
            return popOut(panelId: panelId, from: workspace)
        }
        if let pipPanelId = mostRecentActivePanelId {
            return returnSurface(panelId: pipPanelId)
        }
        return false
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
        guard let host = hostingWindow(for: workspace) else { return false }
        guard let detached = workspace.detachSurface(panelId: panelId) else { return false }

        (detached.panel as? TerminalPanel)?.surface.setFocusPlacement(.pictureInPicture)
        let hostPaneId = homePaneId ?? PaneID()
        let frame = nextFrame(in: host.window.contentView?.bounds ?? .zero)
        let hostView = SurfacePipHostView(
            panel: detached.panel,
            workspaceId: workspace.id,
            paneId: hostPaneId,
            onRequestFocus: { [weak self] in
                self?.focusPipSurface(panelId: panelId)
            }
        )
        let overlayController = SurfacePipOverlayController(
            panelId: panelId,
            hostingWindowId: host.windowId,
            window: host.window,
            title: resolvedTitle(for: detached.panel),
            frame: frame,
            corner: lastCorner,
            contentView: hostView,
            onRequestReturn: { [weak self] panelId in
                self?.returnSurface(panelId: panelId)
            },
            onHostingWindowWillClose: { [weak self] panelId in
                guard let self, let record = self.recordsByPanelId[panelId] else { return }
                self.returnSurface(panelId: panelId, avoidingWindowId: record.hostingWindowId)
            },
            onRequestFocus: { [weak self] panelId in
                self?.focusPipSurface(panelId: panelId)
            },
            onFrameChanged: { [weak self] frame, corner in
                self?.rememberFrame(frame, corner: corner)
            }
        )
        recordsByPanelId[panelId] = Record(
            panelId: panelId,
            homeWorkspaceId: workspace.id,
            homePaneId: homePaneId,
            homeIndex: homeIndex,
            hostingWindowId: host.windowId,
            detached: detached,
            overlayController: overlayController
        )
        rememberFrame(frame, corner: lastCorner)
        activePanelOrder.removeAll { $0 == panelId }
        activePanelOrder.append(panelId)
        overlayController.show()
        focusPipSurface(panelId: panelId)
        return true
    }

    @discardableResult
    func returnSurface(panelId: UUID, avoidingWindowId: UUID? = nil) -> Bool {
        guard let record = recordsByPanelId[panelId],
              let destination = destinationWorkspace(for: record, avoidingWindowId: avoidingWindowId) else {
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
        if focusedPanelId == panelId {
            focusedPanelId = nil
        }
        rememberFrame(record.overlayController.windowRelativeFrame, corner: lastCorner)
        record.overlayController.closeForReturn()
        destination.tabManager.focusTab(destination.workspace.id, surfaceId: panelId, suppressFlash: true)
        focusPipReturnedSurface(panelId: panelId, workspaceId: destination.workspace.id)
        return true
    }

    private func focusPipSurface(panelId: UUID) {
        guard let record = recordsByPanelId[panelId] else { return }
        focusedPanelId = panelId
        activePanelOrder.removeAll { $0 == panelId }
        activePanelOrder.append(panelId)
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

    private func handleFocusSurfaceNotification(_ notification: Notification) {
        guard let panelId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
            focusedPanelId = nil
            return
        }
        guard recordsByPanelId[panelId] != nil else {
            focusedPanelId = nil
            return
        }
        focusedPanelId = panelId
        activePanelOrder.removeAll { $0 == panelId }
        activePanelOrder.append(panelId)
    }

    private func resolvedTitle(for panel: any Panel) -> String {
        let title = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return String(localized: "surfacePip.window.titleFallback", defaultValue: "Picture in Picture")
    }

    private func rememberFrame(_ frame: NSRect, corner: SurfacePipOverlayController.Corner) {
        lastFrame = frame
        lastCorner = corner
    }

    private func nextFrame(in bounds: NSRect) -> NSRect {
        let size = lastFrame?.size ?? NSSize(width: 480, height: 320)
        let base = lastFrame ?? cornerFrame(corner: lastCorner, size: size, in: bounds)
        let offset = CGFloat(recordsByPanelId.count) * 24
        let direction = offsetDirection(for: lastCorner)
        return clampedFrame(
            base.offsetBy(dx: direction.width * offset, dy: direction.height * offset),
            in: bounds
        )
    }

    private func offsetDirection(for corner: SurfacePipOverlayController.Corner) -> NSSize {
        switch corner {
        case .topLeading:
            return NSSize(width: 1, height: -1)
        case .topTrailing:
            return NSSize(width: -1, height: -1)
        case .bottomLeading:
            return NSSize(width: 1, height: 1)
        case .bottomTrailing:
            return NSSize(width: -1, height: 1)
        }
    }

    private func cornerFrame(corner: SurfacePipOverlayController.Corner, size: NSSize, in bounds: NSRect) -> NSRect {
        let width = min(max(240, size.width), max(240, bounds.width / 2))
        let height = min(max(160, size.height), max(160, bounds.height / 2))
        let inset: CGFloat = 16
        switch corner {
        case .topLeading:
            return clampedFrame(NSRect(x: bounds.minX + inset, y: bounds.maxY - inset - height, width: width, height: height), in: bounds)
        case .topTrailing:
            return clampedFrame(NSRect(x: bounds.maxX - inset - width, y: bounds.maxY - inset - height, width: width, height: height), in: bounds)
        case .bottomLeading:
            return clampedFrame(NSRect(x: bounds.minX + inset, y: bounds.minY + inset, width: width, height: height), in: bounds)
        case .bottomTrailing:
            return clampedFrame(NSRect(x: bounds.maxX - inset - width, y: bounds.minY + inset, width: width, height: height), in: bounds)
        }
    }

    private func clampedFrame(_ frame: NSRect, in bounds: NSRect) -> NSRect {
        guard bounds.width > 1, bounds.height > 1 else { return frame }
        let inset: CGFloat = 16
        let availableWidth = max(1, bounds.width - inset * 2)
        let availableHeight = max(1, bounds.height - inset * 2)
        let width = min(max(240, frame.width), min(availableWidth, max(240, bounds.width / 2)))
        let height = min(max(160, frame.height), min(availableHeight, max(160, bounds.height / 2)))
        let minX = bounds.minX + inset
        let minY = bounds.minY + inset
        let maxX = max(minX, bounds.maxX - inset - width)
        let maxY = max(minY, bounds.maxY - inset - height)
        return NSRect(
            x: min(max(frame.minX, minX), maxX),
            y: min(max(frame.minY, minY), maxY),
            width: width,
            height: height
        )
    }

    private func hostingWindow(for workspace: Workspace) -> (windowId: UUID, window: NSWindow)? {
        guard let appDelegate else { return nil }
        if let keyWindow = NSApp.keyWindow,
           let context = appDelegate.contextForMainTerminalWindow(keyWindow),
           context.tabManager.tabs.contains(where: { $0.id == workspace.id }) {
            return (context.windowId, keyWindow)
        }
        if let mainWindow = NSApp.mainWindow,
           let context = appDelegate.contextForMainTerminalWindow(mainWindow),
           context.tabManager.tabs.contains(where: { $0.id == workspace.id }) {
            return (context.windowId, mainWindow)
        }
        for context in appDelegate.mainWindowContexts.values where context.tabManager.tabs.contains(where: { $0.id == workspace.id }) {
            if let window = appDelegate.resolvedWindow(for: context) {
                return (context.windowId, window)
            }
        }
        return nil
    }

    private func destinationWorkspace(
        for record: Record,
        avoidingWindowId: UUID?
    ) -> (tabManager: TabManager, workspace: Workspace, pane: PaneID, index: Int?)? {
        if let home = workspace(id: record.homeWorkspaceId),
           windowIsAllowed(home.tabManager.windowId, avoidingWindowId: avoidingWindowId) {
            let pane = record.homePaneId.flatMap { pane in
                home.workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
            } ?? home.workspace.bonsplitController.focusedPaneId
                ?? home.workspace.bonsplitController.allPaneIds.first
            if let pane {
                return (home.tabManager, home.workspace, pane, record.homeIndex)
            }
        }

        if let focused = focusedWorkspaceFallback(avoidingWindowId: avoidingWindowId) {
            let pane = focused.workspace.bonsplitController.focusedPaneId
                ?? focused.workspace.bonsplitController.allPaneIds.first
            if let pane {
                return (focused.tabManager, focused.workspace, pane, nil)
            }
        }

        return newWorkspaceFallback(avoidingWindowId: avoidingWindowId)
    }

    private func workspace(id: UUID) -> (tabManager: TabManager, workspace: Workspace)? {
        guard let appDelegate,
              let manager = appDelegate.tabManagerFor(tabId: id),
              let workspace = manager.tabs.first(where: { $0.id == id }) else {
            return nil
        }
        return (manager, workspace)
    }

    private func focusedWorkspaceFallback(avoidingWindowId: UUID?) -> (tabManager: TabManager, workspace: Workspace)? {
        guard let appDelegate else { return nil }
        if let manager = appDelegate.tabManager,
           windowIsAllowed(manager.windowId, avoidingWindowId: avoidingWindowId),
           let workspace = manager.selectedWorkspace ?? manager.tabs.first {
            return (manager, workspace)
        }
        for context in appDelegate.mainWindowContexts.values {
            if !windowIsAllowed(context.windowId, avoidingWindowId: avoidingWindowId) { continue }
            if let workspace = context.tabManager.selectedWorkspace ?? context.tabManager.tabs.first {
                return (context.tabManager, workspace)
            }
        }
        return nil
    }

    private func newWorkspaceFallback(
        avoidingWindowId: UUID?
    ) -> (tabManager: TabManager, workspace: Workspace, pane: PaneID, index: Int?)? {
        guard let appDelegate else { return nil }
        let manager: TabManager
        if let existing = firstAvailableTabManager(avoidingWindowId: avoidingWindowId) {
            manager = existing
        } else {
            let windowId = appDelegate.createMainWindow(shouldActivate: false)
            guard windowId != avoidingWindowId,
                  let context = appDelegate.mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
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

    private func firstAvailableTabManager(avoidingWindowId: UUID?) -> TabManager? {
        guard let appDelegate else { return nil }
        if let manager = appDelegate.tabManager,
           windowIsAllowed(manager.windowId, avoidingWindowId: avoidingWindowId) {
            return manager
        }
        return appDelegate.mainWindowContexts.values.first { context in
            windowIsAllowed(context.windowId, avoidingWindowId: avoidingWindowId)
        }?.tabManager
    }

    private func windowIsAllowed(_ windowId: UUID?, avoidingWindowId: UUID?) -> Bool {
        guard let avoidingWindowId else { return true }
        return windowId != avoidingWindowId
    }
}
