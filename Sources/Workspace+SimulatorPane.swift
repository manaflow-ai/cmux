import Bonsplit
import CmuxWorkspaces
import Foundation

/// Simulator pane factory: creates the `SimulatorPanel` surface for one
/// device query. Every entry point (the `simulator.open` socket verb behind
/// `cmux simulator open`) funnels through here so the `simulator.beta.enabled`
/// gate and the no-focus-steal semantics apply identically. Mirrors the
/// workspace-todo surface factory; lives in its own file because
/// `Workspace.swift` sits at its file-length budget.
extension Workspace {
    @discardableResult
    func newSimulatorSurface(
        deviceQuery: String,
        inPane paneId: PaneID,
        focus: Bool? = nil
    ) -> SimulatorPanel? {
        guard SimulatorSurfaceFeature.isEnabled else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let simulatorPanel = SimulatorPanel(workspaceId: id, deviceQuery: deviceQuery)
        panels[simulatorPanel.id] = simulatorPanel
        panelTitles[simulatorPanel.id] = simulatorPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: simulatorPanel.displayTitle,
            icon: simulatorPanel.displayIcon,
            kind: SurfaceKind.simulator.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            simulatorPanel.close()
            panels.removeValue(forKey: simulatorPanel.id)
            panelTitles.removeValue(forKey: simulatorPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: simulatorPanel.id)
        publishCmuxSurfaceCreated(
            simulatorPanel.id,
            paneId: paneId,
            kind: SurfaceKind.simulator.rawValue,
            origin: "simulator_tab",
            focused: shouldFocusNewTab
        )
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

    /// The workspace's simulator panels, for `simulator.close` resolution.
    var simulatorPanels: [SimulatorPanel] {
        panels.values.compactMap { $0 as? SimulatorPanel }
    }
}
