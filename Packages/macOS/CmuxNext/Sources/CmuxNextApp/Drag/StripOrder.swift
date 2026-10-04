import CmuxNextBridge
import CmuxNextTabs

/// One ordering source for a tab strip (R38, Lawrence 2026-10-02: after a
/// reorder Ctrl-1/2/3 selected the wrong tabs). The strip shows a dropped
/// tab at once with an optimistic order; Ctrl-N, Move Tab Left/Right and
/// close-to-the-right read the model's order. The optimistic order now
/// ends when the move settles, and a drop's display index is turned into
/// the pane's own index, so both orders are the same once a move lands.
enum StripOrder {
    /// A tab dragged within its strip. An app-local tab (agent chat,
    /// session browser tab) has no daemon slot to move to: the strip shows
    /// the model's order again.
    static func reorder(_ id: StripTabID, to index: Int, in pane: PaneController) {
        guard pane.tab(id) != nil else { return pane.view.stripView.discardPendingReorder() }
        pane.move(id, toPane: pane, index: index)
    }

    /// The pane (daemon) final index for putting `moving` at `index` of
    /// `pane`'s strip as shown: pinned tabs first, group members together,
    /// closing tabs hidden, app-local tabs last.
    static func paneIndex(forDisplayIndex index: Int, moving: StripTabID, in pane: PaneController) -> Int {
        TabMoveIndex.paneFinalIndex(display: pane.orderedIDs.map(\.rawValue), moving: moving.rawValue, displayIndex: index,
                                    pane: pane.pane.tabs.map(\.id))
    }

    /// The position inside `group` for a drop of `moving` at `index` of
    /// `pane`'s strip as shown (`add-tabs-to-group` takes a group position).
    static func groupIndex(_ index: Int, moving: StripTabID, group: CmuxNextTabs.TabGroupID, in pane: PaneController) -> Int {
        let members = Set(pane.stripModel.orderedTabs.filter { $0.groupID == group }.map(\.id.rawValue))
        return TabMoveIndex.groupIndex(display: pane.orderedIDs.map(\.rawValue), members: members, moving: moving.rawValue,
                                       displayIndex: index)
    }

    /// After a committed move: each strip shows the store's order and
    /// drops its optimistic one.
    static func settle(_ panes: [PaneController?]) {
        for pane in panes.compactMap(\.self) {
            pane.syncStripFromStore()
            pane.view.stripView.discardPendingReorder()
        }
    }
}
