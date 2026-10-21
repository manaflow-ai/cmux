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
    /// screen's or a column's last pane). The focus goes to the pane taking its space when this
    /// pane had it, so keys never go to a pane that left.
    func showPaneClose() -> PendingPaneClose? {
        guard let workspace, let close = workspace.layoutModel.showPaneClose(layoutPaneID) else { return nil }
        if isFocusedInWorkspace, let successor = close.successor {
            workspace.focus.send(.focusPane(successor.rawValue, source: .programmatic))
        }
        // A run that may not move the view (a CLI or agent close) had that focus refused: the
        // topology without this pane takes the focus off it, so keys never go to a pane that left.
        if isFocusedInWorkspace { workspace.sendTopology() }
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
