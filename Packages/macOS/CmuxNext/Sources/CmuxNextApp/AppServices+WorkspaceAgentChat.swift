import CmuxNextAgentPane
import CmuxNextDaemon

extension AppServices {
    /// The agent chat in the workspace of `pane` whose pane was focused last: its tab, view and the
    /// workspace that holds both. Design mode's picks and a terminal selection's comments go to it.
    func workspaceAgentChat(near pane: PaneModel) -> (tab: TabModel, view: AgentPaneView, workspace: WorkspaceModel)? {
        let store = daemon(for: pane).store
        guard let workspace = store.workspace(containing: pane.handle) else { return nil }
        let panes = workspace.screens.flatMap(\.panes).sorted { $0.focusedAt > $1.focusedAt }
        for candidate in panes {
            let selected = candidate.tabs.indices.contains(candidate.defaultTabIndex) ? [candidate.tabs[candidate.defaultTabIndex]] : []
            for tab in selected + candidate.tabs {
                if let view = agentTabs.existingView(tab.id), !agentTabs.isNewTabPage(tab.id) {
                    return (tab, view, workspace)
                }
            }
        }
        return nil
    }
}
