import Bonsplit
import CmuxWorkspaces
import Foundation

/// Creates and focuses the one Subrouter account pane allowed per workspace.
extension Workspace {
    @discardableResult
    func newSubrouterSurface(
        inPane paneId: PaneID,
        service: any SubrouterAccountServicing,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> SubrouterPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView
        let panel = SubrouterPanel(service: service)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let tabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.subrouter.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }

        bindSurface(tabId, toPanelId: panel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(tabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneId,
            kind: SurfaceKind.subrouter.rawValue,
            origin: "subrouter_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: panel.id,
                previousHostedView: previousHostedView
            )
        }
        return panel
    }

    @discardableResult
    func openOrFocusSubrouterSurface(
        inPane paneId: PaneID,
        service: any SubrouterAccountServicing,
        focus: Bool = true
    ) -> SubrouterPanel? {
        if let existing = panels.first(where: { $0.value is SubrouterPanel }) {
            if focus { focusPanel(existing.key) }
            return existing.value as? SubrouterPanel
        }
        return newSubrouterSurface(inPane: paneId, service: service, focus: focus)
    }
}
