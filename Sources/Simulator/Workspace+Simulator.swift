import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func newSimulatorSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        preferredUDID: String? = nil,
        focus: Bool = true
    ) -> SimulatorPanel? {
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }
        guard let paneId = sourcePaneId else { return nil }

        let simulatorPanel = SimulatorPanel(workspaceId: id, preferredUDID: preferredUDID)
        panels[simulatorPanel.id] = simulatorPanel
        panelTitles[simulatorPanel.id] = simulatorPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: simulatorPanel.displayTitle,
            icon: simulatorPanel.displayIcon,
            kind: SurfaceKind.simulator,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = simulatorPanel.id
        let previousFocusedPanelId = focusedPanelId

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: simulatorPanel.id)
            panelTitles.removeValue(forKey: simulatorPanel.id)
            return nil
        }

        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(simulatorPanel.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: simulatorPanel.id,
                previousHostedView: previousHostedView
            )
        }
        return simulatorPanel
    }

    @discardableResult
    func newSimulatorSurface(
        inPane paneId: PaneID,
        preferredUDID: String? = nil,
        focus: Bool? = nil
    ) -> SimulatorPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let simulatorPanel = SimulatorPanel(workspaceId: id, preferredUDID: preferredUDID)
        panels[simulatorPanel.id] = simulatorPanel
        panelTitles[simulatorPanel.id] = simulatorPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: simulatorPanel.displayTitle,
            icon: simulatorPanel.displayIcon,
            kind: SurfaceKind.simulator,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: simulatorPanel.id)
            panelTitles.removeValue(forKey: simulatorPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = simulatorPanel.id
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: simulatorPanel.id,
                previousHostedView: previousHostedView
            )
        }
        return simulatorPanel
    }
}
