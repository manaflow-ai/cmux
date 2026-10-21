/// A pane close shown in the key's turn (plans/cmux-next/close-animation/DESIGN.md): the pane
/// leaves the shown screens, and with `layout.splitSizing` even its chain takes the sizes the close
/// leaves (`CloseSizing`), in one layout. Nothing is sent: the caller sends the close, and the
/// daemon's tree without the pane then shows what is already shown.
extension LayoutModel {
    /// Hides `pane` from the shown screens with its chain's close sizing, in this turn.
    ///
    /// Only a pane with a sibling in its split tree closes this way: the last pane of a screen or
    /// of a column, and a pane in a column with rows, leave with the daemon's tree.
    ///
    /// - Parameter pane: The pane whose last tab (or which) closes.
    /// - Returns: The pending close, for ``settlePaneClose(_:)`` or ``cancelPaneClose(_:)``; nil when
    ///   the pane is not shown, is zoomed, or has no sibling to take its space.
    public func showPaneClose(_ pane: PaneID) -> PendingPaneClose? {
        guard paneCloses[pane] == nil, let screen = screens.first(where: { $0.layout.contains(pane) }), !screen.zoomed,
              let after = Self.removingSplitPane(pane, from: screen.layout) else { return nil }
        let close = PendingPaneClose(pane: pane, successor: Self.successor(of: pane, in: screen.layout), transaction: .make())
        paneCloses[pane] = PaneCloseHold(transaction: close.transaction)
        if splitSizing == .even {
            for change in CloseSizing(old: screen.layout, new: after).splitChanges(closing: pane) {
                let ratio = min(max(change.ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
                splitOverrides[change.split] = Override(value: ratio, transaction: close.transaction, ended: false)
            }
        }
        showOverlaid()
        if focusedPane == pane, let successor = close.successor { focus(successor, notify: false) }
        return close
    }

    /// The daemon accepted the close: the next snapshot says what is true (it was asked after the
    /// close committed), with the pane or without it.
    public func settlePaneClose(_ close: PendingPaneClose) {
        paneCloses[close.pane]?.settled = true
    }

    /// The daemon refused the close: the pane and its chain's sizes come back at once.
    public func cancelPaneClose(_ close: PendingPaneClose) {
        guard paneCloses[close.pane]?.transaction == close.transaction else { return }
        paneCloses[close.pane] = nil
        splitOverrides = splitOverrides.filter { $0.value.transaction != close.transaction }
        showOverlaid()
    }

    /// Whether `pane` is hidden by a pending close.
    public func isClosing(_ pane: PaneID) -> Bool { paneCloses[pane] != nil }

    /// The holds a daemon snapshot ends: the pane left its tree (the close landed; the close sizing
    /// that `applyCloseSizing` sends with it takes over the shown ratios), or the close was settled
    /// and this snapshot is the truth.
    func resolvePaneCloses(in screens: [LayoutScreen]) {
        for (pane, hold) in paneCloses where hold.settled || !screens.contains(where: { $0.layout.contains(pane) }) {
            paneCloses[pane] = nil
            for (split, override) in splitOverrides where override.transaction == hold.transaction {
                splitOverrides[split]?.ended = true
            }
        }
    }
}

/// One pane hidden by a pending close (``LayoutModel/showPaneClose(_:)``).
struct PaneCloseHold {
    var transaction: LayoutTransactionID
    /// The daemon accepted the close: the next snapshot wins.
    var settled = false
}

extension LayoutModel {
    /// `layout` without `pane`, its sibling in its place; nil when `pane` has no sibling in its
    /// split tree (the screen's last pane, a column's only pane) or sits in a column with rows.
    static func removingSplitPane(_ pane: PaneID, from layout: ScreenLayout) -> ScreenLayout? {
        switch layout {
        case let .splits(root):
            return root.contains(pane) ? root.removing(pane).map(ScreenLayout.splits) : nil
        case var .columns(columns):
            guard let index = columns.firstIndex(where: { $0.root.contains(pane) }), !columns[index].hasRows,
                  let root = columns[index].root.removing(pane) else { return nil }
            columns[index].root = root
            return .columns(columns)
        }
    }

    /// The first pane of `pane`'s sibling in its split tree in `layout`.
    static func successor(of pane: PaneID, in layout: ScreenLayout) -> PaneID? {
        let tree: SplitNode? = switch layout {
        case let .splits(root): root
        case .columns: layout.column(containing: pane)?.root
        }
        return tree.flatMap { CloseSizing.parent(of: pane, in: $0)?.1.panes.first }
    }
}
