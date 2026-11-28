package import AppKit
package import CmuxVisibleRows

/// The panel's rows: the document of its scroll view. Only the rows in the
/// visible rect and one viewport on each side have views (`overscan`); a row
/// that scrolls out gives its view back to a pool, and a reload reconfigures
/// only the views whose notification (or its relative time) changed. Heights
/// are measured once per row text with the row's own layout (no Auto Layout),
/// so a reload measures only new or changed rows, and the list's view work does
/// not grow with the ledger (Leo 2026-11-18: "we draw the visible area, right?").
package final class NotificationsPanelList: NSView {
    /// Viewports mounted past each edge of the visible rect.
    static let overscan: CGFloat = 1

    /// The tallest the scroll view shows: what is mounted before the first layout gives it a height.
    package var maxViewportHeight: CGFloat = 440

    /// The row actions, by row.
    package var open: (NotificationsPanelRow) -> Void = { _ in }
    package var dismiss: (NotificationsPanelRow) -> Void = { _ in }
    package var rowMenu: (NotificationsPanelRow) -> NSMenu = { _ in NSMenu() }

    private(set) var rows: [NotificationsPanelRow] = []
    /// Each row's top; the last is the list's height.
    private var offsets: [CGFloat] = [0]
    private var indexByID: [String: Int] = [:]
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

    package var contentHeight: CGFloat { offsets[offsets.count - 1] }

    /// The rows' views in list order: what VoiceOver and a test see.
    var mountedViews: [NotificationRowView] {
        mounted.values.sorted { (indexByID[$0.row.id] ?? 0) < (indexByID[$1.row.id] ?? 0) }
    }

    /// Shows `rows`, newest first, `width` wide. Only a row not measured as it is now is
    /// measured; a new width measures them all again.
    package func show(_ rows: [NotificationsPanelRow], width: CGFloat, now: Date) {
        self.rows = rows
        self.now = now
        if width != measuredWidth { heights = [:]; measuredWidth = width }
        var offsets = [CGFloat](), index = [String: Int](minimumCapacity: rows.count)
        var kept = [String: (row: NotificationsPanelRow, height: CGFloat)](minimumCapacity: rows.count)
        offsets.reserveCapacity(rows.count + 1)
        var y: CGFloat = 0
        for (i, row) in rows.enumerated() {
            offsets.append(y)
            index[row.id] = i
            var height = heights[row.id].flatMap { $0.row.measuresLike(row) ? $0.height : nil }
            if height == nil {
                let sizer = sizer ?? NotificationRowView(row: row, now: now, callbacks: .init(open: {}, dismiss: {}, menu: { NSMenu() }))
                self.sizer = sizer
                sizer.configure(row, now: now)
                height = sizer.height(width: width)
                listWork.laidOut()
            }
            kept[row.id] = (row, height ?? 0)
            y += height ?? 0
        }
        offsets.append(y)
        // The ledger comes whole from the daemon: one pass reads it to find what changed (the index, no view work).
        listWork.walked(rows.count)
        self.offsets = offsets
        indexByID = index
        heights = kept
        if let selectedID, index[selectedID] == nil { self.selectedID = nil }
        setFrameSize(NSSize(width: width, height: y))
        realize()
    }

    /// The rect rows are mounted for: the visible rect and `overscan` viewports on each side.
    private var mountRect: NSRect {
        let visible = enclosingScrollView?.documentVisibleRect ?? .zero
        let viewport = visible.height > 0 ? visible
            : NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, maxViewportHeight))
        return viewport.insetBy(dx: 0, dy: -viewport.height * Self.overscan)
    }

    /// The first row whose bottom is below `y` (a binary search of the offsets).
    private func firstRow(below y: CGFloat) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid + 1] <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Mounts the rows in `mountRect`, keeping their views; the others go back to the pool.
    package func realize() {
        let rect = mountRect
        let first = firstRow(below: rect.minY)
        var end = first
        while end < rows.count, offsets[end] < rect.maxY { end += 1 }
        var keep = [String: NotificationRowView](minimumCapacity: end - first)
        for i in first..<end {
            let row = rows[i]
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
            let frame = NSRect(x: 0, y: offsets[i], width: bounds.width, height: offsets[i + 1] - offsets[i])
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
        guard let id, let index = indexByID[id] else { return }
        mounted[id]?.isSelected = true
        scrollToVisible(NSRect(x: 0, y: offsets[index], width: bounds.width, height: offsets[index + 1] - offsets[index]))
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
