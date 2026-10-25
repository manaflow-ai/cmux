/// A pane close shown in the key's turn (plans/cmux-next/close-animation/DESIGN.md): the pane
/// leaves the shown screens, and with `layout.splitSizing` even its chain takes the sizes the close
/// leaves (`CloseSizing`), in one layout. A column's only pane takes its column with it, and with
/// `layout.newColumnWidth` fitScreen the columns left share the viewport again. Nothing is sent: the
/// caller sends the close, and the daemon's tree without the pane then shows what is already shown.
///
/// Column widths are derived, never held per close: the shown widths are the daemon's, then the
/// widths of closes that landed while others were pending (`landedCloseWidths`), then each pending
/// close in the order it was shown, its fit-screen sizing taken against the layout before it. So
/// overlapping closes, their echoes in any order and a refusal of any of them each show what the
/// closes still pending leave, and the widths go to the daemon once, when the screen's last
/// pending close resolves (`flushLandedCloseWidths`).
extension LayoutModel {
    /// Hides `pane` from the shown screens with its chain's close sizing, in this turn.
    ///
    /// A pane with a sibling in its split tree closes this way, and so does a column's only pane
    /// when another column stays (Leo 2026-10-25: "we should never block shit on the tab
    /// animation"; the column used to wait for the daemon's tree while its emptied strip played the
    /// tab's close). The screen's last pane and a pane in a column with rows leave with the
    /// daemon's tree.
    ///
    /// - Parameter pane: The pane whose last tab (or which) closes.
    /// - Returns: The pending close, for ``settlePaneClose(_:)`` or ``cancelPaneClose(_:)``; nil when
    ///   the pane is not shown, is zoomed, or nothing stays to take its space.
    public func showPaneClose(_ pane: PaneID) -> PendingPaneClose? {
        guard paneCloses[pane] == nil, let screen = screens.first(where: { $0.layout.contains(pane) }), !screen.zoomed,
              let after = Self.removingSplitPane(pane, from: screen.layout) else { return nil }
        let close = PendingPaneClose(pane: pane, successor: Self.successor(of: pane, in: screen.layout), transaction: .make())
        paneCloseSequence += 1
        paneCloses[pane] = PaneCloseHold(transaction: close.transaction, sequence: paneCloseSequence)
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

    /// The daemon refused the close: the pane and its chain's sizes come back at once; the closes
    /// still pending keep theirs, and when none is left the widths of those that landed go out.
    public func cancelPaneClose(_ close: PendingPaneClose) {
        guard paneCloses[close.pane]?.transaction == close.transaction else { return }
        paneCloses[close.pane] = nil
        splitOverrides = splitOverrides.filter { $0.value.transaction != close.transaction }
        showOverlaid()
        flushLandedCloseWidths()
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

    /// The pending closes, in the order they were shown.
    var orderedPaneCloses: [PaneID] {
        paneCloses.sorted { $0.value.sequence < $1.value.sequence }.map(\.key)
    }

    /// `layout` with the landed close widths, then each pending close in order: its pane out and,
    /// under fit-screen, the widths it leaves (``LayoutModel`` above).
    func overlayingPaneCloses(_ layout: ScreenLayout) -> ScreenLayout {
        var layout = applyingLandedCloseWidths(layout)
        let fits = newColumnWidthMode == .fitScreen
        for pane in orderedPaneCloses where layout.contains(pane) {
            guard var after = Self.removingSplitPane(pane, from: layout) else { continue }
            if fits {
                for resize in CloseSizing(old: layout, new: after).columnResizes() { after = after.settingWidth(resize.width, for: resize.column) }
            }
            layout = after
        }
        return layout
    }

    func applyingLandedCloseWidths(_ layout: ScreenLayout) -> ScreenLayout {
        landedCloseWidths.reduce(layout) { layout, entry in
            layout.columns.contains { $0.id == entry.key } ? layout.settingWidth(entry.value, for: entry.key) : layout
        }
    }

    /// Shown closes that landed (`landed` left the daemon's tree between `old` and `new`): under
    /// fit-screen, the widths each screen's change leaves, against the landed widths, join them.
    func noteLandedColumnCloses(from old: [LayoutScreen], to new: [LayoutScreen], landed: Set<PaneID>) {
        guard !landed.isEmpty, newColumnWidthMode == .fitScreen else { return }
        for screen in new {
            guard let before = old.first(where: { $0.id == screen.id }), !before.zoomed, !screen.zoomed,
                  landed.contains(where: { before.layout.contains($0) }) else { continue }
            let resizes = CloseSizing(old: applyingLandedCloseWidths(before.layout), new: applyingLandedCloseWidths(screen.layout)).columnResizes()
            for resize in resizes { landedCloseWidths[resize.column] = resize.width }
        }
    }

    /// Sends the landed close widths of every screen with no close pending, once: the daemon then has
    /// what the screen shows. A width the daemon already has, or of a column gone, is dropped.
    func flushLandedCloseWidths() {
        guard !landedCloseWidths.isEmpty else { return }
        for screen in daemonScreens where !paneCloses.keys.contains(where: { screen.layout.contains($0) }) {
            for column in screen.layout.columns {
                guard let width = landedCloseWidths.removeValue(forKey: column.id) else { continue }
                if abs(width - column.width) > 0.002 { setColumnWidth(column.id, width: width, transaction: .make(), phase: .ended) }
            }
        }
        let live = Set(daemonScreens.flatMap { $0.layout.columns.map(\.id) })
        landedCloseWidths = landedCloseWidths.filter { live.contains($0.key) }
    }
}

/// One pane hidden by a pending close (``LayoutModel/showPaneClose(_:)``).
struct PaneCloseHold {
    var transaction: LayoutTransactionID
    /// The order it was shown in: a later close's sizing is taken after an earlier one's.
    var sequence: Int
    /// The daemon accepted the close: the next snapshot wins.
    var settled = false
}

extension LayoutModel {
    /// `layout` without `pane`: its sibling in its place, or, for a column's only pane, without its
    /// column (``removingColumn(at:from:)``). Nil when `pane` is the screen's last pane or sits in a
    /// column with rows.
    static func removingSplitPane(_ pane: PaneID, from layout: ScreenLayout) -> ScreenLayout? {
        switch layout {
        case let .splits(root):
            return root.contains(pane) ? root.removing(pane).map(ScreenLayout.splits) : nil
        case var .columns(columns):
            guard let index = columns.firstIndex(where: { $0.root.contains(pane) }), !columns[index].hasRows else { return nil }
            guard let root = columns[index].root.removing(pane) else {
                return columns.count > 1 ? removingColumn(at: index, from: columns) : nil
            }
            columns[index].root = root
            return .columns(columns)
        }
    }

    /// `columns` without the column at `index`, as cmux-tui's tree shows it after the close
    /// (`project_layout_columns`, `normalize_dock_columns`): a lone column with one row becomes the
    /// screen's split tree, unless it is a pinned dock (`pinned-dock-alone-v1`), which keeps its
    /// dock and width; another lone column fills the width; when no scrolling column stays, every
    /// dock but a pinned one scrolls again, and a lone column never docks.
    static func removingColumn(at index: Int, from columns: [LayoutColumn]) -> ScreenLayout {
        var columns = columns
        columns.remove(at: index)
        if columns.count == 1, columns[0].dock?.isPinned == true { return .columns(columns) }
        if columns.count == 1, !columns[0].hasRows { return .splits(columns[0].root) }
        if columns.count == 1 { columns[0].width = 1 }
        if columns.count >= 2, columns.allSatisfy({ $0.dock != nil }) {
            for i in columns.indices where columns[i].dock?.isPinned != true { columns[i].dock = nil }
        }
        if columns.count < 2 || columns.allSatisfy({ $0.dock != nil }) {
            for i in columns.indices { columns[i].dock = nil }
        }
        return .columns(columns)
    }

    /// The pane that takes the focus from `pane` (close-focus.md): the first pane of its sibling in
    /// its split tree; for a column's only pane, the first pane of the nearest column to its left
    /// in visual order, else to its right.
    static func successor(of pane: PaneID, in layout: ScreenLayout) -> PaneID? {
        switch layout {
        case let .splits(root):
            return CloseSizing.parent(of: pane, in: root)?.1.panes.first
        case .columns:
            if let root = layout.column(containing: pane)?.root, let sibling = CloseSizing.parent(of: pane, in: root) {
                return sibling.1.panes.first
            }
            let visual = layout.visualColumns
            guard let index = visual.firstIndex(where: { $0.root.contains(pane) }) else { return nil }
            return (visual[..<index].last ?? visual[(index + 1)...].first)?.root.panes.first
        }
    }
}
