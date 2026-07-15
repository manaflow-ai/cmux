import Bonsplit
import CmuxWorkspaces
import Foundation

extension Workspace {
    func openMobilePairingSurface(inPane paneId: PaneID) {
        _ = openOrFocusAppUtilityPane(fromPane: paneId, kind: .mobilePairing, focus: true)
    }

    @discardableResult
    func openOrFocusAppUtilityPane(
        fromPane sourcePaneId: PaneID,
        kind: AppUtilityPanelKind,
        settingsNavigationTarget: SettingsNavigationTarget? = nil,
        focus: Bool = true
    ) -> AppUtilityPanel? {
        // A remote tmux mirror is a 1:1 view of the remote layout. App utility
        // panes are local-only, and asking Bonsplit to split would route the
        // delegate callback to `tmux split-window` before vetoing the local pane.
        guard !isRemoteTmuxMirror else { return nil }

        for (existingId, panel) in panels {
            guard let utilityPanel = panel as? AppUtilityPanel,
                  utilityPanel.kind == kind else {
                continue
            }
            utilityPanel.requestSettingsNavigation(settingsNavigationTarget)
            if focus {
                clearSplitZoom()
                focusPanel(existingId)
            }
            return utilityPanel
        }
        return splitPaneWithAppUtility(
            targetPane: sourcePaneId,
            kind: kind,
            settingsNavigationTarget: settingsNavigationTarget,
            focus: focus
        )
    }

    @discardableResult
    private func splitPaneWithAppUtility(
        targetPane paneId: PaneID,
        kind: AppUtilityPanelKind,
        settingsNavigationTarget: SettingsNavigationTarget? = nil,
        focus: Bool
    ) -> AppUtilityPanel? {
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let utilityPanel = AppUtilityPanel(
            workspaceId: id,
            kind: kind,
            settingsNavigationTarget: settingsNavigationTarget
        )
        panels[utilityPanel.id] = utilityPanel
        panelTitles[utilityPanel.id] = utilityPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: utilityPanel.displayTitle,
            icon: utilityPanel.displayIcon,
            kind: SurfaceKind.appUtility.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: utilityPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: .horizontal,
            withTab: newTab,
            insertFirst: false
        ) else {
            panels.removeValue(forKey: utilityPanel.id)
            panelTitles.removeValue(forKey: utilityPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.appUtilitySplitReparent"
            )
            focusPanel(utilityPanel.id, previousHostedView: previousHostedView)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: utilityPanel.id,
                previousHostedView: previousHostedView
            )
        }
        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: paneId,
            orientation: .horizontal,
            surfaceId: utilityPanel.id,
            kind: SurfaceKind.appUtility.rawValue,
            origin: "app_utility_split",
            focused: focus
        )

        return utilityPanel
    }
}
