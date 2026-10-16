import Bonsplit
import CmuxHomeCore
import CmuxWorkspaces
import Foundation

/// Workspace surface creation for Chief panes: a Chief conversation as a tab or a split.
extension Workspace {
    /// True when this workspace owns its protected canonical Chief Home pane.
    var isChiefHome: Bool {
        panels.values.contains { ($0 as? ChiefPanel)?.isHome == true }
    }

    /// Duplicates a Chief pane into a destination within this workspace.
    /// Canonical Home remains in place; the created pane is an ordinary copy.
    @discardableResult
    func duplicateChiefSurface(
        _ home: ChiefPanel,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> Bool {
        newChiefSurface(
            inPane: paneId,
            conversationID: home.conversationID,
            focus: focus,
            targetIndex: index
        ) != nil
    }

    /// Adds a Chief tab to `paneId`.
    ///
    /// - Parameter conversationID: The conversation to show; nil shows Chief's default conversation.
    @discardableResult
    func newChiefSurface(
        inPane paneId: PaneID,
        conversationID: ConversationID? = nil,
        isHome: Bool = false,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> ChiefPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let chiefPanel = ChiefPanel(conversationID: conversationID, isHome: isHome)
        panels[chiefPanel.id] = chiefPanel
        panelTitles[chiefPanel.id] = chiefPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: chiefPanel.displayTitle,
            icon: chiefPanel.displayIcon,
            iconAsset: ChiefPanel.iconAssetName,
            kind: SurfaceKind.chief.rawValue,
            isDirty: false,
            isLoading: false,
            // Home is protected by the Workspace close delegate, while its
            // Bonsplit tab remains ordinary so it can be dragged and reordered.
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: chiefPanel.id)
            panelTitles.removeValue(forKey: chiefPanel.id)
            pinnedPanelIds.remove(chiefPanel.id)
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
            leaveChiefHomeToShowChiefPane()
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
            isHome: snapshot.isHome ?? false,
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
            iconAsset: ChiefPanel.iconAssetName,
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
            leaveChiefHomeToShowChiefPane()
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

    /// A focused new Chief pane in the window's selected workspace leaves
    /// Chief Home first, so the pane shows at once instead of only after the
    /// workspace is selected again (the palette's "New Chief Pane in Split"
    /// runs from Home too). Unfocused creation (the socket's default) leaves
    /// Home alone: it never takes the user's view.
    private func leaveChiefHomeToShowChiefPane() {
        guard let tabManager = owningTabManager, tabManager.selectedWorkspace === self else { return }
        AppDelegate.shared?.leaveChiefHome(in: tabManager)
    }
}
