import CmuxNextBridge
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

// The panes a caller that puts something into a workspace reads: the model's, always current. A
// workspace parked off screen lays out nothing (its view's `panes` show the tree as of parking), so
// a page tab opened under a top page, or a Settings tab looked for there, must never go by the view.
extension WorkspaceContentController {
    /// The workspace's panes in the model, every screen in order: current whether shown or parked.
    var modelPanes: [PaneModel] { workspace.screens.flatMap(\.panes) }

    /// The controller of model pane `pane`, when this content has one for that very record (a pane
    /// the daemon added while the workspace was parked off screen has none until it shows).
    func controller(for pane: PaneModel) -> PaneController? {
        panes[LayoutPaneID(pane.id)].flatMap { $0.pane === pane ? $0 : nil }
    }

    /// The model pane a new page tab opens in: the focused pane, unless it sits in a dock column;
    /// then the first pane of the first column of its screen that is not a dock (``pageTabPane``,
    /// read from the model). The first pane in the model when the focus names none of its panes.
    var pageTabModelPane: PaneModel? {
        let panes = modelPanes
        let focused = focus.state.pane.flatMap { id in panes.first { $0.id == id } } ?? panes.first
        guard let focused,
              let screen = workspace.screens.first(where: { $0.columns.contains { $0.layout.paneIDs.contains(focused.handle) } }),
              screen.columns.contains(where: { $0.dock != nil && $0.layout.paneIDs.contains(focused.handle) }) else { return focused }
        for column in screen.columns where column.dock == nil {
            if let pane = column.layout.paneIDs.lazy.compactMap({ id in screen.panes.first { $0.handle == id } }).first { return pane }
        }
        return focused
    }
}
