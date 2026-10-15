import Bonsplit
import CmuxHomeCore
import CmuxWorkspaces
import Foundation

/// Workspace surface creation for Chief panes: a Chief conversation as a tab or a split.
extension Workspace {
    /// Adds a Chief tab to `paneId`.
    ///
    /// - Parameter conversationID: The conversation to show; nil shows Chief's default conversation.
    @discardableResult
    func newChiefSurface(
        inPane paneId: PaneID,
        conversationID: ConversationID? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> ChiefPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let chiefPanel = ChiefPanel(conversationID: conversationID)
        panels[chiefPanel.id] = chiefPanel
        panelTitles[chiefPanel.id] = chiefPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: chiefPanel.displayTitle,
            icon: chiefPanel.displayIcon,
            kind: SurfaceKind.chief.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: chiefPanel.id)
            panelTitles.removeValue(forKey: chiefPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: chiefPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            chiefPanel.id,
            paneId: paneId,
            kind: SurfaceKind.chief.rawValue,
            origin: "chief_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: chiefPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return chiefPanel
    }

    /// Recreates a persisted Chief pane in `paneId` without taking focus.
    func restoreChiefSurface(inPane paneId: PaneID, snapshot: SessionChiefPanelSnapshot) -> ChiefPanel? {
        newChiefSurface(
            inPane: paneId,
            conversationID: snapshot.conversationID.map(ConversationID.init(rawValue:)),
            focus: false
        )
    }

    /// Focuses this workspace's Chief pane showing `conversationID`, or adds one to `paneId`.
    @discardableResult
    func openOrFocusChiefSurface(
        inPane paneId: PaneID,
        conversationID: ConversationID? = nil,
        focus: Bool = true
    ) -> ChiefPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        for (existingId, panel) in panels {
            guard let chiefPanel = panel as? ChiefPanel,
                  chiefPanel.conversationID == conversationID else { continue }
            if focus {
                focusPanel(existingId)
            }
            return chiefPanel
        }
        return newChiefSurface(inPane: paneId, conversationID: conversationID, focus: focus)
    }

    /// Opens Chief in a new split beside the pane that holds `panelId`.
    @discardableResult
    func newChiefSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        conversationID: ConversationID? = nil,
        focus: Bool = true,
        initialDividerPosition: CGFloat? = nil
    ) -> ChiefPanel? {
        guard !isRetiredFromOwningTabManager,
              let sourceTabId = surfaceIdFromPanelId(panelId),
              let sourcePaneId = bonsplitController.allPaneIds.first(where: { paneId in
                  bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == sourceTabId })
              }),
              admitsSplitSpacePreflight(
                  splitting: sourcePaneId,
                  orientation: orientation,
                  dividerPosition: initialDividerPosition
              ) else {
            return nil
        }

        let chiefPanel = ChiefPanel(conversationID: conversationID)
        panels[chiefPanel.id] = chiefPanel
        panelTitles[chiefPanel.id] = chiefPanel.displayTitle
        let tab = Bonsplit.Tab(
            title: chiefPanel.displayTitle,
            icon: chiefPanel.displayIcon,
            kind: SurfaceKind.chief.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(tab.id, toPanelId: chiefPanel.id)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = withSplitSpaceDividerPosition(initialDividerPosition, {
            bonsplitController.splitPane(
                sourcePaneId,
                orientation: orientation,
                withTab: tab,
                insertFirst: insertFirst,
                initialDividerPosition: initialDividerPosition
            )
        }) else {
            removeSurfaceMapping(forSurfaceId: tab.id)
            panels.removeValue(forKey: chiefPanel.id)
            panelTitles.removeValue(forKey: chiefPanel.id)
            chiefPanel.close()
            return nil
        }

        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: sourcePaneId,
            orientation: orientation,
            surfaceId: chiefPanel.id,
            kind: SurfaceKind.chief.rawValue,
            origin: "chief_split",
            focused: focus
        )

        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.chiefSplitReparent"
            )
            focusPanel(chiefPanel.id, previousHostedView: previousHostedView)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: chiefPanel.id,
                previousHostedView: previousHostedView
            )
        }
        return chiefPanel
    }
}
