import AppKit
import CmuxNextBridge
import CmuxNextDesign

extension AppServices {
    /// Shows tab `id` the way a user's jump does (Go To in history, Search
    /// Tabs): the window that lists its workspace comes forward (made key
    /// only while the app is active), the workspace, screen and tab are
    /// selected and its pane takes focus. Returns false when no connected
    /// machine has the tab.
    @discardableResult
    func revealTab(_ id: String) -> Bool {
        guard let (_, paneModel) = locateTab(id),
              let workspace = daemon(for: paneModel).store.workspace(containing: paneModel.handle),
              let window = windows.reveal(workspaceID: workspace.id) else { return false }
        window.state.selection.select(id, in: paneModel.id)
        window.focus.send(.selectTab(pane: paneModel.id, tab: id, workspace: workspace.id, source: .intent))
        paneController(for: paneModel)?.select(StripTabID(id))
        if let nsWindow = window.window { WindowActivation.show(nsWindow, .raise) }
        return true
    }
}
