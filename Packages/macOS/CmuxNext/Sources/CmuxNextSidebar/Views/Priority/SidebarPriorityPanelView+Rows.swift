import AppKit
import CmuxNextWakeups
import CmuxVisibleRows

/// The Priority view's drawn rows: each chat's slot from `tops`, the rows in the clip and one viewport above and
/// below. Under the visible-rows contract (`VisibleRowsContract`): a new row, a configure and a tick's redraw count as
/// configured on `listWork`, each row frame set as laid out, and the index of every chat a change rebuilds as walked.
extension SidebarPriorityPanelView: VisibleRowsList {
    /// Chat row views in the document: the drawn rows and the ones still closing their slot (not the Archived fold).
    var rowViewsAlive: Int { document.subviews.reduce(0) { $0 + ($1 is SidebarPriorityRowView ? 1 : 0) } }

    /// The row is whole at `frame` with no move in flight, so landing it there again changes nothing.
    static func landed(_ row: SidebarPriorityRowView, at frame: NSRect) -> Bool {
        row.slot == frame && row.frame == frame && row.alphaValue == 1 && !row.clipsToBounds
            && (row.layer?.animationKeys()?.isEmpty ?? true)
    }

    /// The rows to draw in rank order: those in the clip and one viewport above and below (`drawnRange`), and
    /// the held and the focused row wherever they are (a drag or the keyboard keeps its row).
    func drawnIndices() -> [Int] {
        let range = drawnRange()
        let focused = (window?.firstResponder as? SidebarPriorityRowView).flatMap { $0.superview === document ? $0.entry.id : nil }
        let extra = Set([draggingID, focused].compactMap { $0.flatMap { places[$0] } }.filter { !range.contains($0) })
        guard !extra.isEmpty else { return Array(range) }
        return (Array(range) + extra).sorted()
    }

    /// The rows in the clip's bounds and one viewport above and below (`VisibleRowsIndex.drawnRange`); none while
    /// folded. Before the clip has a height (a panel shown before its first layout) the panel's own body stands in.
    private func drawnRange() -> Range<Int> {
        guard !panel.collapsed else { return 0..<0 }
        let visible = clip.bounds
        let height = visible.height > 0 ? visible.height : max(0, bounds.height - headerHeight)
        return rowIndex.drawnRange(top: visible.minY, height: height)
    }

    /// The slot a held row at `from` whose middle is at `middle` drops into (`VisibleRowsIndex.dropSlot`, a search).
    func dropSlot(from: Int, middle: CGFloat) -> Int { rowIndex.dropSlot(from: from, middle: middle) }

    func slotFrame(_ index: Int, width: CGFloat) -> NSRect {
        NSRect(x: 0, y: tops[index], width: width, height: tops[index + 1] - tops[index])
    }

    /// `tops` and `places` for `panel.entries`: four row heights at the current type sizes, not a measure per chat.
    func reindex() {
        let heights = [false, true].flatMap { preview in
            [false, true].map { SidebarPriorityRowView.height(hasPreview: preview, answerable: $0) }
        }
        rowIndex = VisibleRowsIndex(panel.entries, id: \.id) { heights[($0.preview != nil ? 2 : 0) + ($0.answerable ? 1 : 0)] }
        listWork.walked(panel.entries.count)
    }

    /// After a scroll or a resize: the rows that came into the drawn range get views at their slots, and those
    /// that left it go. The rows still drawn are not touched.
    func realizeDrawnRows() {
        let width = clip.bounds.width
        guard document.frame.width == width else { return placeRows(animated: false) }
        var kept = Set<String>()
        for index in drawnIndices() {
            let entry = panel.entries[index]
            kept.insert(entry.id)
            guard rows[entry.id] == nil else { continue }
            let row = mount(entry), frame = slotFrame(index, width: width)
            row.frame = frame
            row.slot = frame
            listWork.laidOut()
        }
        for id in rows.keys where !kept.contains(id) && !slidingOut.contains(id) { unmount(id) }
    }

    /// A view for `entry`'s row in the document.
    func mount(_ entry: SidebarPriorityEntry) -> SidebarPriorityRowView {
        let row = SidebarPriorityRowView(entry: entry)
        listWork.configured()
        row.statusWords = panel.statusWords
        row.onAction = { [weak self] action in self?.onAction?(action) }
        row.onMove = { [weak self, weak row] direction in
            guard let self, let row else { return }
            self.move(row.entry.id, direction: direction)
        }
        row.onDrag = { [weak self] row, offset, ended in self?.drag(row, offset: offset, ended: ended) }
        document.addSubview(row)
        rows[entry.id] = row
        return row
    }

    /// Takes `id`'s row out of the document: it left the drawn range.
    func unmount(_ id: String) {
        guard let row = rows.removeValue(forKey: id) else { return }
        row.onAction = nil
        row.onDrag = nil
        row.onMove = nil
        opensUntil[ObjectIdentifier(row)] = nil
        row.removeFromSuperview()
    }

    /// The scroll moved: the rows it revealed come and those it left go, and a held row follows it, as a
    /// pointer move would.
    func clipScrolled() {
        realizeDrawnRows()
        guard let id = draggingID, let row = rows[id] else { return }
        drag(row, offset: dragPointerOffset, ended: false)
    }

    /// A chip says minutes: one redraw a minute while a row works, none otherwise.
    func updateTicker() {
        let working = !panel.collapsed && panel.entries.contains { if case .working = $0.state { true } else { false } }
        guard working else { return ticker.cancel() }
        ticker.scheduleIfIdle(after: .seconds(60)) { @MainActor [weak self] in
            guard let self else { return }
            self.tick(now: Date())
            self.updateTicker()
        }
    }

    /// Redraws the drawn rows whose working time reads differently at `now`; the others are not touched.
    func tick(now: Date) {
        for row in rows.values where row.tick(now: now) { listWork.configured() }
    }
}

/// The Priority view's clip view: it reports each scroll (a wheel, a scroller drag, a programmatic scroll) so a held
/// row can follow the document, and each resize, so the rows drawn follow the viewport.
final class ScrollReportingClipView: NSClipView {
    var onScroll: (() -> Void)?
    var onResize: (() -> Void)?

    override func scroll(to newOrigin: NSPoint) {
        setBoundsOrigin(newOrigin)
        onScroll?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }
}
