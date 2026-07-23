import Bonsplit
import CmuxWorkspaces
import Foundation

/// Surface navigation and sidebar status helpers extracted from `Workspace.swift`, which sits at its file-length budget.
extension Workspace {
    /// Moves the focused surface into an existing neighboring bonsplit pane.
    ///
    /// This intentionally delegates the mutation to `moveSurface` so keyboard,
    /// command-palette, menu, and local tab-context pane actions share the same
    /// ownership transfer, source-pane cleanup, and focus restoration path.
    @discardableResult
    func moveSelectedSurfaceToAdjacentPane(_ direction: NavigationDirection) -> Bool {
        guard let panelId = focusedPanelId else { return false }
        return moveSurfaceToAdjacentPane(panelId: panelId, direction: direction)
    }

    /// Moves the focused surface to the previous or next pane in the split
    /// tree's stable spatial order (top-to-bottom, then left-to-right).
    @discardableResult
    func moveSelectedSurfaceToPane(offset: Int) -> Bool {
        guard offset != 0,
              layoutMode != .canvas,
              !isRemoteTmuxMirror,
              let panelId = focusedPanelId,
              let sourcePaneId = paneId(forPanelId: panelId) else {
            return false
        }

        let orderedPaneIds = spatiallyOrderedPaneIds
        guard let sourceIndex = orderedPaneIds.firstIndex(of: sourcePaneId.id) else {
            return false
        }
        guard orderedPaneIds.count > 1 else { return false }
        let paneCount = orderedPaneIds.count
        let destinationIndex = (sourceIndex + offset % paneCount + paneCount) % paneCount
        guard let destinationPaneId = bonsplitController.allPaneIds.first(where: {
            $0.id == orderedPaneIds[destinationIndex]
        }),
              destinationPaneId != sourcePaneId else {
            return false
        }

        clearSplitZoom()
        return moveSurface(
            panelId: panelId,
            toPane: destinationPaneId,
            atIndex: insertionIndexAfterSelectedTab(in: destinationPaneId),
            focus: true
        )
    }

    func insertionIndexAfterSelectedTab(in paneId: PaneID) -> Int {
        let destinationTabs = bonsplitController.tabs(inPane: paneId)
        guard let selectedTabId = bonsplitController.selectedTab(inPane: paneId)?.id,
              let selectedIndex = destinationTabs.firstIndex(where: { $0.id == selectedTabId }) else {
            return destinationTabs.count
        }
        return selectedIndex + 1
    }

    /// Notification unread lookup for sidebar surface indicators.
    func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    /// Surface-kind mapping used by workspace state snapshots.
    func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal.rawValue
        case .browser:
            return SurfaceKind.browser.rawValue
        case .markdown:
            return SurfaceKind.markdown.rawValue
        case .filePreview:
            return SurfaceKind.filePreview.rawValue
        case .rightSidebarTool:
            return SurfaceKind.rightSidebarTool.rawValue
        case .customSidebar:
            return SurfaceKind.customSidebar.rawValue
        case .agentSession:
            return SurfaceKind.agentSession.rawValue
        case .project:
            return SurfaceKind.project.rawValue
        case .extensionBrowser:
            return SurfaceKind.extensionBrowser.rawValue
        case .workspaceTodo:
            return SurfaceKind.todo.rawValue
        case .cloudVMLoading:
            return SurfaceKind.cloudVMLoading.rawValue
        }
    }

    /// Select the next surface in the currently focused split pane, or in
    /// workspace Canvas order when Canvas layout is active.
    func selectNextSurface() {
        if layoutMode == .canvas {
            _ = selectAdjacentCanvasTab(offset: 1)
            return
        }
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused split pane, or in
    /// workspace Canvas order when Canvas layout is active.
    func selectPreviousSurface() {
        if layoutMode == .canvas {
            _ = selectAdjacentCanvasTab(offset: -1)
            return
        }
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Moves the selected surface within its focused split or Canvas pane
    /// without wrapping.
    @discardableResult
    func moveSelectedSurface(by offset: Int) -> Bool {
        if layoutMode == .canvas {
            guard let focusedPanelId else { return false }
            return reorderSurface(panelId: focusedPanelId, by: offset)
        }
        guard let paneId = bonsplitController.focusedPaneId,
              let selectedTab = bonsplitController.selectedTab(inPane: paneId),
              let panelId = panelIdFromSurfaceId(selectedTab.id) else { return false }
        return reorderSurface(panelId: panelId, by: offset)
    }

    /// Reorders one surface by a relative final-position offset in the
    /// current layout's authoritative tab model.
    @discardableResult
    func reorderSurface(panelId: UUID, by offset: Int) -> Bool {
        if layoutMode == .canvas {
            let previousRevision = canvasModel.revision
            guard canvasModel.reorderPanel(panelId, by: offset) else { return false }
            if canvasModel.revision != previousRevision {
                canvasModel.viewport?.modelDidChangeExternally(animated: false)
            }
            return true
        }
        guard let paneId = paneId(forPanelId: panelId),
              let tabId = surfaceIdFromPanelId(panelId) else { return false }
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }), !tabs.isEmpty else { return false }
        let finalIndex = min(max(currentIndex + offset, tabs.startIndex), tabs.index(before: tabs.endIndex))
        guard finalIndex != currentIndex else { return true }
        let insertionIndex = finalIndex > currentIndex ? finalIndex + 1 : finalIndex
        return reorderSurface(panelId: panelId, toIndex: insertionIndex)
    }

    /// Select a surface by index in the currently focused split pane, or in
    /// workspace Canvas order when Canvas layout is active.
    func selectSurface(at index: Int) {
        if layoutMode == .canvas {
            _ = selectCanvasTab(at: index)
            return
        }
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard tabs.indices.contains(index) else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused split pane, or in
    /// workspace Canvas order when Canvas layout is active.
    func selectLastSurface() {
        if layoutMode == .canvas {
            _ = selectLastCanvasTab()
            return
        }
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }
}
