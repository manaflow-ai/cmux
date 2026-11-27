package import AppKit
package import CmuxVisibleRows

/// The panel's rows: the document of its scroll view. Only the rows in the
/// visible rect and one viewport on each side have views (`overscan`); a row
/// that scrolls out gives its view back to a pool, and a reload reconfigures
/// only the views whose notification (or its relative time) changed. Heights
/// are measured once per row text with the row's own layout (no Auto Layout).
/// A ledger delta (`apply`) reads, measures and indexes only the rows it names,
/// so the list's work per notification does not grow with the ledger (Leo
/// 2026-11-18: "we draw the visible area, right?").
package final class NotificationsPanelList: NSView {
    /// Viewports mounted past each edge of the visible rect.
    static let overscan: CGFloat = 1

    /// The tallest the scroll view shows: what is mounted before the first layout gives it a height.
    package var maxViewportHeight: CGFloat = 440

    /// The row actions, by row.
    package var open: (NotificationsPanelRow) -> Void = { _ in }
    package var dismiss: (NotificationsPanelRow) -> Void = { _ in }
    package var rowMenu: (NotificationsPanelRow) -> NSMenu = { _ in NSMenu() }

    /// The rows newest first, their index by id and their tops.
    private var ledger = NotificationsPanelLedger()
    /// Each row's measured height and the row it was measured as, by id, at `measuredWidth`.
    private var heights: [String: (row: NotificationsPanelRow, height: CGFloat)] = [:]
    private var measuredWidth: CGFloat = 0
    /// The rows that have views, by id.
    private(set) var mounted: [String: NotificationRowView] = [:]
    private var pool: [NotificationRowView] = []
    /// Measures rows that have no view; never in a window.
    private var sizer: NotificationRowView?
    private var now = Date()
    private(set) var selectedID: String?
    /// The rows this list configured, laid out and walked (the visible-rows contract).
    package let listWork = ListWorkMeter()
    /// Views parked for reuse past this many are dropped: a scroll step parks one or two.
    private static let poolLimit = 2

    nonisolated override package var isFlipped: Bool { true }

    package var contentHeight: CGFloat { ledger.height }
    package var count: Int { ledger.count }
    package var unreadCount: Int { ledger.unreadCount }
    package func row(at index: Int) -> NotificationsPanelRow { ledger.rows[index] }
    package func index(of id: String) -> Int? { ledger.index(of: id) }
    package func row(id: String) -> NotificationsPanelRow? { ledger.index(of: id).map { ledger.rows[$0] } }

    /// The rows' views in list order: what VoiceOver and a test see.
    var mountedViews: [NotificationRowView] {
        mounted.values.sorted { (ledger.index(of: $0.row.id) ?? 0) < (ledger.index(of: $1.row.id) ?? 0) }
    }

    /// Shows `rows` (the whole ledger), newest first, `width` wide. Only a row not measured as it is now is
    /// measured; a new width measures them all again.
    package func show(_ rows: [NotificationsPanelRow], width: CGFloat, now: Date) {
        self.now = now
        if width != measuredWidth { heights = [:]; measuredWidth = width }
        var kept = [String: (row: NotificationsPanelRow, height: CGFloat)](minimumCapacity: rows.count)
        let rowHeights = rows.map { row in
            let height = measure(row)
            kept[row.id] = (row, height)
            return height
        }
        // The whole ledger: one pass reads it to find what changed (the index, no view work).
        listWork.walked(rows.count)
        heights = kept
        ledger.replace(rows, heights: rowHeights)
        if let selectedID, ledger.index(of: selectedID) == nil { self.selectedID = nil }
        setFrameSize(NSSize(width: width, height: ledger.height))
        realize()
    }

    /// Shows a ledger reply's rows: the whole ledger, or with `removed` (a delta) only the rows that changed.
    package func show(_ rows: [NotificationsPanelRow], removed: [String]?, width: CGFloat, now: Date) {
        guard let removed else { return show(rows, width: width, now: now) }
        apply(upserted: rows, removed: removed, width: width, now: now)
    }

    /// Applies a ledger delta: `upserted` rows (new or changed, newest first) and the ids `removed`. Reads,
    /// measures and indexes only those rows; the mounted ones are configured again.
    package func apply(upserted: [NotificationsPanelRow], removed: [String], width: CGFloat, now: Date) {
        guard width == measuredWidth else {
            // A new width measures every row: the whole ledger with the delta in it.
            let gone = Set(removed).union(upserted.map(\.id))
            let merged = (upserted + ledger.rows.filter { !gone.contains($0.id) }).sorted { $0.createdAt > $1.createdAt }
            return show(merged, width: width, now: now)
        }
        self.now = now
        for id in removed {
            guard let index = ledger.index(of: id) else { continue }
            ledger.remove(at: index)
            heights[id] = nil
            if selectedID == id { selectedID = nil }
        }
        // Oldest first, so new rows that tie on time stack newest on top.
        for row in upserted.reversed() {
            let height = measure(row)
            heights[row.id] = (row, height)
            if let index = ledger.index(of: row.id) {
                ledger.update(at: index, row, height: height)
            } else {
                ledger.insert(row, at: ledger.insertionIndex(row), height: height)
            }
        }
        listWork.walked(upserted.count + removed.count)
        setFrameSize(NSSize(width: width, height: ledger.height))
        realize()
    }

    /// `row`'s height at `measuredWidth`: the one it was measured at while its text is the same.
    private func measure(_ row: NotificationsPanelRow) -> CGFloat {
        if let known = heights[row.id], known.row.measuresLike(row) { return known.height }
        let sizer = sizer ?? NotificationRowView(row: row, now: now, callbacks: .init(open: {}, dismiss: {}, menu: { NSMenu() }))
        self.sizer = sizer
        sizer.configure(row, now: now)
        listWork.laidOut()
        return sizer.height(width: measuredWidth)
    }

    /// The rect rows are mounted for: the visible rect and `overscan` viewports on each side.
    private var mountRect: NSRect {
        let visible = enclosingScrollView?.documentVisibleRect ?? .zero
        let viewport = visible.height > 0 ? visible
            : NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, maxViewportHeight))
        return viewport.insetBy(dx: 0, dy: -viewport.height * Self.overscan)
    }

    /// The first row whose bottom is below `y` (a binary search of the tops).
    private func firstRow(below y: CGFloat) -> Int {
        var low = 0, high = ledger.count
        while low < high {
            let mid = (low + high) / 2
            if ledger.top(mid + 1) <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Mounts the rows in `mountRect` with their times relative to `now`.
    package func realize(now: Date) {
        self.now = now
        realize()
    }

    /// Mounts the rows in `mountRect`, keeping their views; the others go back to the pool.
    package func realize() {
        let rect = mountRect
        let first = firstRow(below: rect.minY)
        var end = first
        while end < ledger.count, ledger.top(end) < rect.maxY { end += 1 }
        var keep = [String: NotificationRowView](minimumCapacity: end - first)
        for i in first..<end {
            let row = ledger.rows[i]
            let view: NotificationRowView
            if let existing = mounted.removeValue(forKey: row.id) {
                view = existing
                if view.configure(row, now: now) { listWork.configured() }
            } else {
                view = pool.popLast() ?? makeView(row)
                view.configure(row, now: now)
                listWork.configured()
                addSubview(view)
            }
            view.isSelected = row.id == selectedID
            let frame = NSRect(x: 0, y: ledger.top(i), width: bounds.width, height: ledger.rowHeight(i))
            if view.frame != frame { view.frame = frame; listWork.laidOut() }
            keep[row.id] = view
        }
        for view in mounted.values {
            view.removeFromSuperview()
            if pool.count < Self.poolLimit { pool.append(view) }
        }
        mounted = keep
    }

    private func makeView(_ row: NotificationsPanelRow) -> NotificationRowView {
        let view = NotificationRowView(row: row, now: now, callbacks: .init(open: {}, dismiss: {}, menu: { NSMenu() }))
        // The actions read the view's row when they run: a reused view acts on the row it shows.
        view.callbacks = .init(
            open: { [weak self, weak view] in if let view { self?.open(view.row) } },
            dismiss: { [weak self, weak view] in if let view { self?.dismiss(view.row) } },
            menu: { [weak self, weak view] in view.flatMap { self?.rowMenu($0.row) } ?? NSMenu() }
        )
        return view
    }

    /// Selects the row `id` names (nil: none) and scrolls it into view; touches only the rows it changes.
    package func select(_ id: String?) {
        if let old = selectedID, old != id { mounted[old]?.isSelected = false }
        selectedID = id
        guard let id, let index = ledger.index(of: id) else { return }
        mounted[id]?.isSelected = true
        scrollToVisible(NSRect(x: 0, y: ledger.top(index), width: bounds.width, height: ledger.rowHeight(index)))
    }
}

extension NotificationsPanelRow {
    /// Whether `other` measures as this row did: the same text and the same title weight.
    func measuresLike(_ other: NotificationsPanelRow) -> Bool {
        title == other.title && subtitle == other.subtitle && body == other.body && unread == other.unread
            && source == other.source && workspaceTitle == other.workspaceTitle
    }
}

extension NotificationsPanelList: VisibleRowsList {
    /// The rows shown and the views parked for reuse.
    package var rowViewsAlive: Int { mounted.count + pool.count }
}
