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
