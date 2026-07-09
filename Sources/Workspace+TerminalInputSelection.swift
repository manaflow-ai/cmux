import Bonsplit
import Foundation

/// Selects the terminal panel a workspace-targeted control command (the v1
/// `send_workspace` path) should deliver input to, reproducing the legacy
/// resolution order verbatim: the focused pane's selected terminal, else the
/// last remembered config-inheritance terminal when it is still the selected
/// tab in some pane, else the first pane (in `bonsplitController.allPaneIds`
/// order) whose selected tab is a terminal. Relocated from `TerminalController`'s
/// v1 send/notify conformance so this byte-identical, purely `Workspace`-state
/// selection is owned by `Workspace`.
extension Workspace {
    func sendableWorkspaceTerminalPanel() -> TerminalPanel? {
        func selectedTerminalPanel(in paneId: PaneID) -> TerminalPanel? {
            guard let selectedTab = bonsplitController.selectedTab(inPane: paneId),
                  let panelId = panelIdFromSurfaceId(selectedTab.id),
                  let terminalPanel = panels[panelId] as? TerminalPanel else {
                return nil
            }
            return terminalPanel
        }

        func isSelectedTerminalPanel(_ terminalPanel: TerminalPanel) -> Bool {
            guard let surfaceId = surfaceIdFromPanelId(terminalPanel.id) else {
                return false
            }
            return bonsplitController.allPaneIds.contains { paneId in
                bonsplitController.selectedTab(inPane: paneId)?.id == surfaceId
            }
        }

        if let focusedPane = bonsplitController.focusedPaneId,
           let terminalPanel = selectedTerminalPanel(in: focusedPane) {
            return terminalPanel
        }

        if let rememberedTerminal = lastRememberedTerminalPanelForConfigInheritance(),
           isSelectedTerminalPanel(rememberedTerminal) {
            return rememberedTerminal
        }

        for paneId in bonsplitController.allPaneIds {
            if let terminalPanel = selectedTerminalPanel(in: paneId) {
                return terminalPanel
            }
        }

        return nil
    }
}
