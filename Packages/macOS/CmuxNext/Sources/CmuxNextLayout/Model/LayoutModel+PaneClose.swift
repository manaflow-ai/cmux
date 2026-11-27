/// A pane close shown in the key's turn (plans/cmux-next/close-animation/DESIGN.md): the pane
/// leaves the shown screens, and with `layout.splitSizing` even its chain takes the sizes the close
/// leaves (`CloseSizing`), in one layout. A column's only pane takes its column with it, and with
/// `layout.newColumnWidth` fitScreen the columns left share the viewport again. Nothing is sent: the
/// caller sends the close, and the daemon's tree without the pane then shows what is already shown.
///
/// A close's sizes (split ratios under `layout.splitSizing` even, column widths under
/// `layout.newColumnWidth` fitScreen) are derived, never held per split or column: the shown sizes
/// are the daemon's, then the sizes of closes that landed while others were pending
/// (`landedCloseRatios`, `landedCloseWidths`), then each pending close in the order it was shown,
/// its sizing taken against the layout before it. So overlapping closes, in one split chain or
/// across columns, their echoes in any order and a refusal of any of them each show what the
/// closes still pending leave, and the sizes go to the daemon once, when the screen's last pending
/// close resolves (`flushLandedCloseSizes`).
extension LayoutModel {
    /// Hides `pane` from the shown screens with its chain's close sizing, in this turn.
    ///
    /// A pane with a sibling in its split tree closes this way, and so does a column's only pane
    /// when another column stays (Leo 2026-10-25: "we should never block shit on the tab
    /// animation"; the column used to wait for the daemon's tree while its emptied strip played the
    /// tab's close), and so does a pane in a column with rows (its row's tree loses it; a row it
    /// empties leaves the column, ``removingRowPane(_:from:)``). The screen's last pane leaves with
    /// the daemon's tree.
    ///
    /// - Parameter pane: The pane whose last tab (or which) closes.
    /// - Returns: The pending close, for ``settlePaneClose(_:)`` or ``cancelPaneClose(_:)``; nil when
    ///   the pane is not shown, is zoomed, or nothing stays to take its space.
    public func showPaneClose(_ pane: PaneID) -> PendingPaneClose? {
        guard let (screen, after) = paneCloseShown(pane) else { return nil }
        let close = PendingPaneClose(pane: pane, successor: Self.successor(of: pane, in: screen.layout), transaction: .make())
        paneCloseSequence += 1
        paneCloses[pane] = PaneCloseHold(transaction: close.transaction, sequence: paneCloseSequence)
        // The sizes this close leaves supersede sent sizes the daemon has not acknowledged yet for the
        // same splits and columns (an earlier close's flush): those apply after the closes in `overlaid`
        // and would hold the chain at the older sizes until their reply.
        if splitSizing == .even {
            supersedeSentRatios(Set(CloseSizing(old: screen.layout, new: after).splitChanges(closing: pane).map(\.split)))
        }
        if newColumnWidthMode == .fitScreen {
            let kept = Set(after.columns.map(\.id)), gone = screen.layout.columns.map(\.id).filter { !kept.contains($0) }
            supersedeSentWidths(Set(CloseSizing(old: screen.layout, new: after).columnResizes().map(\.column) + gone))
        }
        showOverlaid()
        if focusedPane == pane, let successor = close.successor { focus(successor, notify: false) }
        return close
    }

    /// Whether ``showPaneClose(_:)`` would show `pane`'s close now (it changes nothing): a close
    /// that may still be rolled back (a terminal's close while the daemon's read decides) hides the
    /// pane only when the layout can show it leaving.
    public func canShowPaneClose(_ pane: PaneID) -> Bool { paneCloseShown(pane) != nil }

    /// `pane`'s screen and its layout without `pane`, when its close can be shown.
    private func paneCloseShown(_ pane: PaneID) -> (screen: LayoutScreen, after: ScreenLayout)? {
        guard paneCloses[pane] == nil, let screen = screens.first(where: { $0.layout.contains(pane) }), !screen.zoomed,
              let after = Self.removingSplitPane(pane, from: screen.layout) else { return nil }
        return (screen, after)
    }

    /// The daemon accepted the close: the next snapshot says what is true (it was asked after the
    /// close committed), with the pane or without it.
    public func settlePaneClose(_ close: PendingPaneClose) {
        paneCloses[close.pane]?.settled = true
    }

    /// The daemon refused the close: the pane and its chain's sizes come back at once; the closes
    /// still pending keep theirs, and when none is left the sizes of those that landed go out.
    public func cancelPaneClose(_ close: PendingPaneClose) {
        guard paneCloses[close.pane]?.transaction == close.transaction else { return }
        paneCloses[close.pane] = nil
        showOverlaid()
        flushLandedCloseSizes()
    }

    /// Takes back `pane`'s pending close, whoever showed it, as a refusal does: the caller shows the pane
    /// again (a rolled-back hide) or hands the close on to one shown in this same turn.
    /// - Returns: Whether a close was pending.
    @discardableResult
    public func withdrawPaneClose(_ pane: PaneID) -> Bool {
        guard let hold = paneCloses[pane] else { return false }
        cancelPaneClose(PendingPaneClose(pane: pane, successor: nil, transaction: hold.transaction))
        return true
    }

    /// Whether `pane` is hidden by a pending close.
    public func isClosing(_ pane: PaneID) -> Bool { paneCloses[pane] != nil }

    /// The holds a daemon snapshot ends: the pane left its tree (the close landed; its sizes are
    /// the landed close sizes, `noteLandedCloses`), or the close was settled and this snapshot is
    /// the truth.
    func resolvePaneCloses(in screens: [LayoutScreen]) {
        for (pane, hold) in paneCloses where hold.settled || !screens.contains(where: { $0.layout.contains(pane) }) {
            paneCloses[pane] = nil
        }
    }

    /// The pending closes, in the order they were shown.
    var orderedPaneCloses: [PaneID] {
        paneCloses.sorted { $0.value.sequence < $1.value.sequence }.map(\.key)
    }

    /// `layout` with the landed close sizes, then each pending close in order: its pane out and the
    /// sizes it leaves, its chain's even ratios and, under fit-screen, its columns' widths
    /// (``LayoutModel`` above).
    func overlayingPaneCloses(_ layout: ScreenLayout) -> ScreenLayout {
        var layout = applyingLandedCloseSizes(layout)
        let even = splitSizing == .even, fits = newColumnWidthMode == .fitScreen
        for pane in orderedPaneCloses where layout.contains(pane) {
            guard var after = Self.removingSplitPane(pane, from: layout) else { continue }
            let sizing = CloseSizing(old: layout, new: after)
            if even {
                for change in sizing.splitChanges(closing: pane) { after = after.settingRatio(Self.clampedRatio(change.ratio), for: change.split) }
            }
            if fits {
                for resize in sizing.columnResizes() { after = after.settingWidth(resize.width, for: resize.column) }
            }
            layout = after
        }
        return layout
    }

    static func clampedRatio(_ ratio: Double) -> Double {
        min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
    }

    func applyingLandedCloseSizes(_ layout: ScreenLayout) -> ScreenLayout {
        let ratios = landedCloseRatios.reduce(layout) { layout, entry in
            layout.ratio(of: entry.key) == nil ? layout : layout.settingRatio(entry.value, for: entry.key)
        }
        return landedCloseWidths.reduce(ratios) { layout, entry in
            layout.columns.contains { $0.id == entry.key } ? layout.settingWidth(entry.value, for: entry.key) : layout
        }
    }

    /// Shown closes that landed (`landed` left the daemon's tree between `old` and `new`): the sizes
    /// each screen's change leaves, against the landed sizes, join them (even ratios of each landed
    /// pane's chain, and under fit-screen the column widths).
    func noteLandedCloses(from old: [LayoutScreen], to new: [LayoutScreen], landed: Set<PaneID>) {
        guard !landed.isEmpty else { return }
        for screen in new {
            guard let before = old.first(where: { $0.id == screen.id }), !before.zoomed, !screen.zoomed,
                  landed.contains(where: { before.layout.contains($0) }) else { continue }
            // One by one in show order, against a running tree: closes that land in one snapshot (adjacent
            // panes, each the other's sibling) each size what the one before left, as the overlay showed.
            var current = applyingLandedCloseSizes(before.layout)
            for pane in orderedPaneCloses where landed.contains(pane) && current.contains(pane) && !screen.layout.contains(pane) {
                guard var after = Self.removingSplitPane(pane, from: current) else { continue }
                let sizing = CloseSizing(old: current, new: after)
                if splitSizing == .even {
                    for change in sizing.splitChanges(closing: pane) {
                        landedCloseRatios[change.split] = Self.clampedRatio(change.ratio)
                        after = after.settingRatio(Self.clampedRatio(change.ratio), for: change.split)
                    }
                }
                if newColumnWidthMode == .fitScreen {
                    for resize in sizing.columnResizes() {
                        landedCloseWidths[resize.column] = resize.width
                        after = after.settingWidth(resize.width, for: resize.column)
                    }
                }
                current = after
            }
        }
    }

    /// Sends the landed close sizes of every screen with no close pending, once: the daemon then has
    /// what the screen shows. A size the daemon already has, or of a split or column gone, is dropped.
    func flushLandedCloseSizes() {
        guard !landedCloseWidths.isEmpty || !landedCloseRatios.isEmpty else { return }
        for screen in daemonScreens where !paneCloses.keys.contains(where: { screen.layout.contains($0) }) {
            for (split, ratio) in landedCloseRatios {
                guard let shown = screen.layout.ratio(of: split) else { continue }
                landedCloseRatios[split] = nil
                if abs(ratio - shown) > 0.002 { setSplitRatio(split, ratio: ratio, transaction: .make(), phase: .ended) }
            }
            for column in screen.layout.columns {
                guard let width = landedCloseWidths.removeValue(forKey: column.id) else { continue }
                if abs(width - column.width) > 0.002 { setColumnWidth(column.id, width: width, transaction: .make(), phase: .ended) }
            }
        }
        let columns = Set(daemonScreens.flatMap { $0.layout.columns.map(\.id) })
        landedCloseWidths = landedCloseWidths.filter { columns.contains($0.key) }
        landedCloseRatios = landedCloseRatios.filter { entry in daemonScreens.contains { $0.layout.ratio(of: entry.key) != nil } }
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
    /// column (``removingColumn(at:from:)``), or, in a column with rows, out of its row
    /// (``removingRowPane(_:from:)``). Nil when `pane` is the screen's last pane.
    static func removingSplitPane(_ pane: PaneID, from layout: ScreenLayout) -> ScreenLayout? {
        switch layout {
        case let .splits(root):
            return root.contains(pane) ? root.removing(pane).map(ScreenLayout.splits) : nil
        case var .columns(columns):
            guard let index = columns.firstIndex(where: { $0.root.contains(pane) }) else { return nil }
            if columns[index].hasRows {
                // A pane in no row (one the rows did not map) leaves with the daemon's tree.
                guard columns[index].row(containing: pane) != nil else { return nil }
                releasingChatRole(of: &columns[index], closing: pane)
                columns[index] = removingRowPane(pane, from: columns[index])
                // A lone column left with one row is the screen's split tree again
                // (`project_layout_columns`), unless it is a pinned dock.
                if columns.count == 1, !columns[0].hasRows, columns[0].dock?.isPinned != true { return .splits(columns[0].root) }
                return .columns(columns)
            }
            guard let root = columns[index].root.removing(pane) else {
                return columns.count > 1 ? removingColumn(at: index, from: columns) : nil
            }
            releasingChatRole(of: &columns[index], closing: pane)
            columns[index].root = root
            return .columns(columns)
        }
    }

    /// `column` (with two or more rows) without `pane`, as cmux-tui's tree shows it after the close
    /// (`remove_pane_from_screen_layout`, then `LayoutColumn::normalize_rows`): the pane leaves its
    /// row's tree, its sibling in its place; a row it empties leaves the column (the top row's going
    /// leaves the next row's id and height as the top); the rows left keep their heights; a column
    /// left with one row is a plain column whose tree is that row's. The compat chain `root` is
    /// refolded from the rows: chain split k is row k's (ids and splits as the daemon's chain had
    /// them), its ratio the heights above it over the heights through it, in `f32` as the daemon
    /// computes it.
    static func removingRowPane(_ pane: PaneID, from column: LayoutColumn) -> LayoutColumn {
        guard let index = column.rows.firstIndex(where: { $0.root.contains(pane) }) else { return column }
        var column = column
        // The chain's splits, top first: `chain[k - 1]` joins rows 0..<k above row k.
        var chain: [SplitID] = []
        var node = column.root
        while chain.count < column.rows.count - 1, case .split(let id, .vertical, _, let a, _) = node {
            chain.append(id)
            node = a
        }
        chain.reverse()
        guard chain.count == column.rows.count - 1 else {
            // Not the chain the daemon builds: the compat tree just loses the pane.
            column.root = column.root.removing(pane) ?? column.root
            if let root = column.rows[index].root.removing(pane) { column.rows[index].root = root } else { column.rows.remove(at: index) }
            if column.rows.count < 2 { column.rows = [] }
            return column
        }
        if let root = column.rows[index].root.removing(pane) {
            column.rows[index].root = root
        } else {
            // The emptied row's split goes; for the top row, the split under it (the next row is the top now).
            column.rows.remove(at: index)
            chain.remove(at: max(index - 1, 0))
        }
        guard column.rows.count >= 2 else {
            column.root = column.rows[0].root
            column.rows = []
            return column
        }
        var root = column.rows[0].root
        var before = Float(column.rows[0].height)
        for (row, split) in zip(column.rows.dropFirst(), chain) {
            let height = Float(row.height)
            let ratio = clampedRatio(Double(before / (before + height)))
            root = .split(split, axis: .vertical, ratio: ratio, a: root, b: row.root)
            before += height
        }
        column.root = root
        return column
    }

    /// The agent chat's own pane (its dock's top pane, read before the close) leaving while panes
    /// stay below it: the dock stays on its edge as a plain dock (cmux-tui `release_agent_chat_role`).
    static func releasingChatRole(of column: inout LayoutColumn, closing pane: PaneID) {
        guard column.dock?.role == .agentChat, column.root.panes.first == pane else { return }
        column.dock?.role = nil
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
    /// its split tree (its row's, in a column with rows); for a row's only pane, the first pane of
    /// the row above, else below; for a column's only pane, the first pane of the nearest column to
    /// its left in visual order, else to its right.
    static func successor(of pane: PaneID, in layout: ScreenLayout) -> PaneID? {
        switch layout {
        case let .splits(root):
            return CloseSizing.parent(of: pane, in: root)?.1.panes.first
        case .columns:
            if let column = layout.column(containing: pane), let tree = column.tree(containing: pane) {
                if let sibling = CloseSizing.parent(of: pane, in: tree) { return sibling.1.panes.first }
                if column.hasRows, let index = column.rows.firstIndex(where: { $0.root.contains(pane) }) {
                    return (index > 0 ? column.rows[index - 1] : column.rows[index + 1]).root.panes.first
                }
            }
            let visual = layout.visualColumns
            guard let index = visual.firstIndex(where: { $0.root.contains(pane) }) else { return nil }
            return (visual[..<index].last ?? visual[(index + 1)...].first)?.root.panes.first
        }
    }
}
