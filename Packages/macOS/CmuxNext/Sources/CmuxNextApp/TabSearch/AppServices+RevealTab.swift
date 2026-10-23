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
    ///   - id: A daemon tab's id (`TabModel.id`), agent chat tabs included.
    ///   - intent: How the window comes forward; `.bringForward` leaves the
    ///     key window alone (a link opened in the background).
    @discardableResult
    func revealTab(_ id: String, intent: WindowActivation.Intent = .raise) -> Bool {
        reveal(locateTab(id), id: id, intent: intent)
    }

    /// ``revealTab(_:intent:)`` for tab `id` on machine `machineID` only, never a tab of
    /// another machine that shares the id (Go to What Needs Me's rows name their machine).
    /// Windows find a workspace by its id alone, so a workspace whose id another machine's
    /// workspace also has (a cloned machine's) is refused rather than shown as the other one.
    @discardableResult
    func revealTab(_ id: String, onMachine machineID: String, intent: WindowActivation.Intent = .raise) -> Bool {
        guard let daemon = machines.daemons.first(where: { $0.machineID == machineID }),
              let tab = daemon.store.tab(idOrResource: id), let pane = daemon.store.pane(holding: tab),
              let workspace = daemon.store.workspace(containing: pane.handle),
              machines.workspace(id: workspace.id)?.1 === daemon else { return false }
        return reveal((tab, pane), id: id, intent: intent)
    }

    private func reveal(_ located: (TabModel, PaneModel)?, id: String, intent: WindowActivation.Intent) -> Bool {
        // A `tab_` link names a tab the strip may know by its first id.
        let tabID = located?.0.id ?? id
        guard let paneModel = located?.1,
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
