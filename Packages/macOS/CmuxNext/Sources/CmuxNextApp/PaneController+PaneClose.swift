import CmuxNextBridge
import CmuxNextFocus
import CmuxNextLayout

/// A pane that closes as a whole (its last tab, or Close Pane) leaves its window in the key's
/// turn: the layout hides it with the even sizes the close leaves, so its neighbours spring into
/// its space on one motion from the key's frame, not after the daemon's echo
/// (plans/cmux-next/close-animation/DESIGN.md). The daemon still decides: a refused close brings
/// the pane back.
extension PaneController {
    /// Shows this pane's close now; nil when the layout leaves it to the daemon's tree (the
    /// screen's last pane, a pane in a column with rows). A column's only pane takes its column.
    ///
    /// When this pane had the focus, the focus reducer picks its successor, as for any close
    /// (`layout.closeFocus` and this window's focus history, close-focus.md): it gets the topology
    /// without this pane now, so keys never go to a pane that left and the daemon's echo finds the
    /// focus where its own topology would put it. No pane is named here (a run that may not move
    /// the view still has the focus taken off the closed pane: a topology is no view change).
    func showPaneClose() -> PendingPaneClose? {
        guard let workspace, let close = workspace.layoutModel.showPaneClose(layoutPaneID) else { return nil }
        if isFocusedInWorkspace {
            // The held topology with this pane taken out: no rebuild over every pane (the echo's apply
            // sends the close's one built topology, the perf gate's split budget). A topology a pane
            // marked changed this turn is built first, from the layout without this pane.
            let held = workspace.focus.currentState().topology
            if held.contains(pane: paneKey) { workspace.focus.send(.topology(held.removing(pane: paneKey))) }
            // The layout shows the reducer's pick in this frame, with or without the window's applier.
            if let pane = workspace.focus.state.pane, pane != paneKey { workspace.layoutModel.focus(LayoutPaneID(pane), notify: false) }
        }
        // The store tree has not changed: the view mirrors the hidden pane now, and the daemon's
        // echo is the close's one apply and topology (the perf gate's split budget).
        workspace.layoutView.syncWithModel()
        return close
    }

    /// The close's outcome: a refused close shows the pane again; an accepted one lets the next
    /// snapshot say what is true.
    func finishPaneClose(_ close: PendingPaneClose?, failed: Bool) {
        guard let close, let workspace else { return }
        if failed {
            workspace.layoutModel.cancelPaneClose(close)
            workspace.applyCurrent()
        } else {
            workspace.layoutModel.settlePaneClose(close)
        }
    }
}
