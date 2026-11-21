import Foundation

// Zoom and swap as intents (Toggle Pane Zoom, the Swap Pane actions, a pane drag): the screen shows the change in the
// input's turn, not on the daemon's `layout-changed`. Both intents name the resulting state, so they are idempotent:
// once the daemon's layout holds the same zoom or the same pane order, the restore after its apply changes nothing, and
// the held publication (``IntentUndo/heldScreen``) wakes no reader.
extension IntentOverlay {
    /// `pane`'s screen shows it alone (`zoomed`) or shows its whole layout again; nil when it already does, or when
    /// `pane` is not in the records or still opening (the daemon has no pane to zoom yet; the command is refused).
    static func zoom(_ pane: PaneID, zoomed: Bool, in store: DaemonStore) -> IntentUndo? {
        guard !ProvisionalPane.isStandIn(pane), let screen = store.screen(containing: pane) else { return nil }
        // cmux-tui's `zoom_pane_as`: `on` zooms this pane, `off` unzooms the screen whichever pane it shows.
        let next = zoomed ? pane : nil
        guard screen.zoomedPane != next else { return nil }
        let previous = screen.zoomedPane
        screen.zoomedPane = next
        return .screenZoom(screen: screen.handle, pane: previous)
    }

    /// Puts `leading` before `trailing` in their screen's pane order by exchanging the two; nil when it already is, or
    /// when they are not two panes of one screen's layout, or one is still opening (the daemon refuses those).
    static func swap(leading: PaneID, trailing: PaneID, in store: DaemonStore) -> IntentUndo? {
        guard leading != trailing, !ProvisionalPane.isStandIn(leading), !ProvisionalPane.isStandIn(trailing),
              let screen = store.screen(containing: leading), store.screen(containing: trailing) === screen else { return nil }
        let order = paneOrder(of: screen)
        guard let first = order.firstIndex(of: leading), let second = order.firstIndex(of: trailing), first > second else { return nil }
        exchange(leading, trailing, in: screen)
        return .swappedPanes(screen: screen.handle, first: leading, second: trailing)
    }

    /// The screen's panes in layout order: its columns left to right on a column screen, else its split tree.
    static func paneOrder(of screen: ScreenModel) -> [PaneID] {
        screen.columns.isEmpty ? screen.layout.paneIDs : screen.columns.flatMap(\.layout.paneIDs)
    }

    /// Exchanges two panes in everything that places them: the screen's tree, each column's tree and each row's
    /// (cmux-tui's `swap_layout_panes`). Sizes, the zoom and the active pane stay. Its own inverse.
    static func exchange(_ first: PaneID, _ second: PaneID, in screen: ScreenModel) {
        let layout = screen.layout.swappingPanes(first, second)
        if layout != screen.layout { screen.layout = layout }
        let columns = screen.columns.map { column in
            var column = column
            column.layout = column.layout.swappingPanes(first, second)
            column.rows = column.rows.map { row in
                var row = row
                row.layout = row.layout.swappingPanes(first, second)
                return row
            }
            return column
        }
        if columns != screen.columns { screen.columns = columns }
    }
}

extension LayoutNode {
    /// The tree with `first` and `second` in each other's place (cmux-tui's `swap_leaf_ids`). A stack that holds
    /// exactly one of them and showed it expanded shows the other one expanded; one that holds both keeps its
    /// expanded pane. Applied twice it gives the tree back.
    func swappingPanes(_ first: PaneID, _ second: PaneID) -> LayoutNode {
        func other(_ pane: PaneID) -> PaneID { pane == first ? second : pane == second ? first : pane }
        switch self {
        case .leaf(let pane):
            return .leaf(other(pane))
        case .split(let id, let resourceID, let direction, let ratio, let a, let b):
            return .split(id: id, resourceID: resourceID, direction: direction, ratio: ratio,
                          a: a.swappingPanes(first, second), b: b.swappingPanes(first, second))
        case .stack(let panes, let expanded):
            let holdsOne = panes.contains(first) != panes.contains(second)
            return .stack(panes: panes.map(other), expanded: holdsOne ? other(expanded) : expanded)
        case .unknown:
            return self
        }
    }
}

extension DaemonStore {
    /// The intent that shows `pane` and `other` in each other's place (`swap-pane` with `target`): the one of the two
    /// that is later in their screen's pane order now leads after the swap. When they are not two panes of one screen
    /// the intent shows nothing (``IntentOverlay/swap(leading:trailing:in:)``) and the daemon's refusal is reported.
    ///
    /// - Parameters:
    ///   - pane: The pane the swap is run on.
    ///   - other: The pane it changes places with.
    /// - Returns: ``Intent/swapPanes(leading:trailing:)``.
    public func swapIntent(of pane: PaneID, with other: PaneID) -> Intent {
        let order = screen(containing: pane).map { IntentOverlay.paneOrder(of: $0) } ?? []
        if let place = order.firstIndex(of: pane), let otherPlace = order.firstIndex(of: other), place > otherPlace {
            return .swapPanes(leading: pane, trailing: other)
        }
        return .swapPanes(leading: other, trailing: pane)
    }
}
