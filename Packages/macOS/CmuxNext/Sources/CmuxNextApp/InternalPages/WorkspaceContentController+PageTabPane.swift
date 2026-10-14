import CmuxNextDaemon

extension WorkspaceContentController {
    /// The pane a new page tab (Settings, Channels, any app page) opens in: the focused pane,
    /// unless it sits in a dock column (an agent chat dock, the docked Home page, cx-ebm.59.5).
    /// Then the first pane of the first column that is not a dock on its screen, so the page opens
    /// in the workspace beside the dock, never in it. The focused pane when that screen has only docks.
    var pageTabPane: PaneController? {
        guard let focused = focusedPane else { return nil }
        let handle = focused.pane.handle
        guard let screen = workspace.screens.first(where: { $0.columns.contains { $0.layout.paneIDs.contains(handle) } }),
              screen.columns.contains(where: { $0.dock != nil && $0.layout.paneIDs.contains(handle) }) else { return focused }
        for column in screen.columns where column.dock == nil {
            for id in column.layout.paneIDs {
                if let pane = pane(for: id) { return pane }
            }
        }
        return focused
    }
}
