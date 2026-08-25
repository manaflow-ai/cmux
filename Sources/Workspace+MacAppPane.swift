import Bonsplit
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Creates a Mac App mirror tab in an existing pane.
    @discardableResult
    func newMacAppSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> MacAppPanel? {
        guard !isRemoteTmuxMirror else { return nil }
        let shouldFocus = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView
        let panel = MacAppPanel()
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let tabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.macApp.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }

        bindSurface(tabId, toPanelId: panel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(tabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneId,
            kind: SurfaceKind.macApp.rawValue,
            origin: "mac_app_tab",
            focused: shouldFocus
        )

        if shouldFocus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else if let previousFocusedPanelId {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: panel.id,
                previousHostedView: previousHostedView
            )
        }
        return panel
    }

    /// Creates a Mac App mirror in a new split pane.
    @discardableResult
    func newMacAppSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true,
        initialDividerPosition: CGFloat? = nil
    ) -> MacAppPanel? {
        guard !isRemoteTmuxMirror,
              let sourceTabId = surfaceIdFromPanelId(panelId),
              let sourcePaneId = bonsplitController.allPaneIds.first(where: { paneId in
                  bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == sourceTabId })
              }) else {
            return nil
        }

        let panel = MacAppPanel()
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle
        let tab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.macApp.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(tab.id, toPanelId: panel.id)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            sourcePaneId,
            orientation: orientation,
            withTab: tab,
            insertFirst: insertFirst
        ) else {
            removeSurfaceMapping(forSurfaceId: tab.id)
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }

        applyInitialSplitDividerPosition(
            initialDividerPosition,
            sourcePaneId: sourcePaneId,
            newPaneId: newPaneId
        )
        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: sourcePaneId,
            orientation: orientation,
            surfaceId: panel.id,
            kind: SurfaceKind.macApp.rawValue,
            origin: "mac_app_split",
            focused: focus
        )

        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.macAppSplitReparent"
            )
            focusPanel(panel.id, previousHostedView: previousHostedView)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: panel.id,
                previousHostedView: previousHostedView
            )
        }
        return panel
    }
}
