import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

extension AppServices {
    /// Shows tab `id` the way a user's jump does (Go To in history, Search
    /// Tabs, a `cmux://` link): the window that lists its workspace comes
    /// forward (made key only while the app is active), the workspace,
    /// screen and tab are selected and its pane takes focus. Returns false
    /// when no connected machine has the tab.
    ///
    /// - Parameters:
    ///   - id: A daemon tab's id (`TabModel.id`) or an agent tab's
    ///     (`local-agent:…`).
    ///   - intent: How the window comes forward; `.bringForward` leaves the
    ///     key window alone (a link opened in the background).
    @discardableResult
    func revealTab(_ id: String, intent: WindowActivation.Intent = .raise) -> Bool {
        let located = locateTab(id)
        // A `tab_` link names a tab the strip may know by its first id.
        let tabID = located?.0.id ?? id
        guard let paneModel = located?.1 ?? agentTabs.paneKey(listing: id).flatMap({ pane(id: $0) }),
              let workspace = daemon(for: paneModel).store.workspace(containing: paneModel.handle),
              let window = windows.reveal(workspaceID: workspace.id) else { return false }
        window.state.selection.select(tabID, in: paneModel.id)
        window.focus.send(.selectTab(pane: paneModel.id, tab: tabID, workspace: workspace.id, source: .intent))
        paneController(for: paneModel)?.select(StripTabID(tabID))
        if let nsWindow = window.window { showJumpWindow(nsWindow, intent) }
        return true
    }

    /// The pane with id `id` on any connected machine: its `PaneModel.id`,
    /// or its `pane_` resource id when the model was first seen without one
    /// (its id is then `pane:<handle>`).
    func pane(id: String) -> PaneModel? {
        for (workspace, _) in machines.allWorkspaces {
            for screen in workspace.screens {
                if let pane = screen.panes.first(where: { $0.id == id || $0.resourceID?.rawValue == id }) { return pane }
            }
        }
        return nil
    }
}
