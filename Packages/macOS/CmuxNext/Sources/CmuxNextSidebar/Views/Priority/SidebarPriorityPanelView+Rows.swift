import AppKit
import CmuxNextWakeups

/// The Priority view's drawn rows: each chat's slot from `tops`, the rows in the clip and one viewport above and
/// below, and the work counts the count tests read (`SidebarPriorityRenderCountTests`).
extension SidebarPriorityPanelView {
    /// The panel's row work.
    struct Counts: Equatable {
        /// Row views made (a row coming into view).
        var made = 0
        /// Row configures, a new row's own included.
        var configured = 0
        /// Row frames set (placed, moved or landed).
        var framed = 0
        /// Rows a clock tick redrew (their working time read differently).
        var ticked = 0
    }

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

    /// The rows in the clip's bounds and one viewport above and below; none while folded. Before the clip has a
    /// height (a panel shown before its first layout) the panel's own body stands in for it.
    private func drawnRange() -> Range<Int> {
        guard !panel.collapsed, !panel.entries.isEmpty else { return 0..<0 }
        let visible = clip.bounds
        let height = visible.height > 0 ? visible.height : max(0, bounds.height - headerHeight)
        guard height > 0 else { return 0..<0 }
        let lower = row(below: visible.minY - height)
        let upper = min(panel.entries.count, row(below: visible.minY + 2 * height) + 1)
        return lower..<max(lower, upper)
    }

    /// The first row whose bottom is below `y` (`entries.count` past the last): a search of `tops`, not a walk.
    private func row(below y: CGFloat) -> Int {
        var low = 0, high = panel.entries.count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid + 1] <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The slot a held row at `from` whose middle is at `middle` drops into: the other rows whose middle is above
    /// it. The middles rise in rank order, so a search of `tops` finds them, not a walk of every chat.
    func dropSlot(from: Int, middle: CGFloat) -> Int {
        var low = 0, high = panel.entries.count
        while low < high {
            let mid = (low + high) / 2
            if (tops[mid] + tops[mid + 1]) / 2 < middle { low = mid + 1 } else { high = mid }
        }
        return low - ((tops[from] + tops[from + 1]) / 2 < middle ? 1 : 0)
    }

    func slotFrame(_ index: Int, width: CGFloat) -> NSRect {
        NSRect(x: 0, y: tops[index], width: width, height: tops[index + 1] - tops[index])
    }

    /// `tops` and `places` for `panel.entries`: four row heights at the current type sizes, not a measure per chat.
    func reindex() {
        let heights = [false, true].flatMap { preview in
            [false, true].map { SidebarPriorityRowView.height(hasPreview: preview, answerable: $0) }
        }
        var tops: [CGFloat] = [], places: [String: Int] = [:]
        tops.reserveCapacity(panel.entries.count + 1)
        places.reserveCapacity(panel.entries.count)
        var y: CGFloat = 0
        for (index, entry) in panel.entries.enumerated() {
            tops.append(y)
            places[entry.id] = index
            y += heights[(entry.preview != nil ? 2 : 0) + (entry.answerable ? 1 : 0)]
        }
        tops.append(y)
        self.tops = tops
        self.places = places
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
            counts.framed += 1
        }
        for id in rows.keys where !kept.contains(id) && !slidingOut.contains(id) { unmount(id) }
    }

    /// A view for `entry`'s row in the document.
    func mount(_ entry: SidebarPriorityEntry) -> SidebarPriorityRowView {
        let row = SidebarPriorityRowView(entry: entry)
        counts.made += 1
        counts.configured += 1
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
        for row in rows.values where row.tick(now: now) { counts.ticked += 1 }
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
