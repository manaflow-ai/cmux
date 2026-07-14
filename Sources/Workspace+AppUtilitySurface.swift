import Bonsplit
import CmuxWorkspaces
import Foundation

extension Workspace {
    func openMobilePairingSurface(inPane paneId: PaneID) {
        _ = openOrFocusAppUtilitySurface(inPane: paneId, kind: .mobilePairing, focus: true)
    }

    @discardableResult
    func openOrFocusAppUtilitySurface(
        inPane paneId: PaneID,
        kind: AppUtilityPanel.Kind,
        settingsNavigationTarget: SettingsNavigationTarget? = nil,
        focus: Bool = true
    ) -> AppUtilityPanel? {
        for (existingId, panel) in panels {
            guard let utilityPanel = panel as? AppUtilityPanel,
                  utilityPanel.kind == kind else {
                continue
            }
            utilityPanel.requestSettingsNavigation(settingsNavigationTarget)
            if focus {
                focusPanel(existingId)
            }
            return utilityPanel
        }
        return newAppUtilitySurface(
            inPane: paneId,
            kind: kind,
            settingsNavigationTarget: settingsNavigationTarget,
            focus: focus
        )
    }

    @discardableResult
    func newAppUtilitySurface(
        inPane paneId: PaneID,
        kind: AppUtilityPanel.Kind,
        settingsNavigationTarget: SettingsNavigationTarget? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> AppUtilityPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let utilityPanel = AppUtilityPanel(
            workspaceId: id,
            kind: kind,
            settingsNavigationTarget: settingsNavigationTarget
        )
        panels[utilityPanel.id] = utilityPanel
        panelTitles[utilityPanel.id] = utilityPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: utilityPanel.displayTitle,
            icon: utilityPanel.displayIcon,
            kind: SurfaceKind.appUtility.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: utilityPanel.id)
            panelTitles.removeValue(forKey: utilityPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: utilityPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            utilityPanel.id,
            paneId: paneId,
            kind: SurfaceKind.appUtility.rawValue,
            origin: "app_utility_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            focusPanel(utilityPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: utilityPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return utilityPanel
    }
}
