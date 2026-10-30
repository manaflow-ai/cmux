import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The Priority view at the top of the sidebar, under the titlebar row: every agent chat ranked by
/// what needs the person (the App ranks them), a header that folds it to one line with a count, and
/// its own scroll past its share of the sidebar's height. When a chat's rank changes its row slides
/// to its new place on the sidebar's move spring; a new row opens its slot and a leaving row closes its.
/// The person can drag a row to another place; it stays there (the App keeps it, `.place`), and the
/// other chats rank around it (Leo 2026-10-21).
final class SidebarPriorityPanelView: NSView {
    var onAction: ((SidebarPriorityAction) -> Void)?
    /// The panel's height changed (rows came or went, it folded): the sidebar lays out again.
    var onHeightChange: (() -> Void)?

    private let header = SidebarSectionHeaderView()
    private let count = ChromeLabel(labelWithString: "")
    private let empty = ChromeLabel(labelWithString: Strings.priorityEmpty)
    private let scroll = NSScrollView()
    private lazy var fade = ScrollEdgeFadeView(scrollView: scroll)
    private let document = FlippedDocument()
    private(set) var rows: [String: SidebarPriorityRowView] = [:]
    /// Rows that left and still close their slot; they go when their move ends. They take no clicks
    /// (`FlippedDocument.hitTest`), so a right-click there opens no menu for a chat that left.
    private var closing: [SidebarPriorityRowView] = []
    /// The number of the last animated placement (`placeRows`), and for each row still opening its
    /// slot the placement whose end unclips it: a row whose slot changes again while it opens keeps
    /// clipping until the later move ends, as the main list's `opens` count does.
    private var placement = 0
    private var opensUntil: [ObjectIdentifier: Int] = [:]
    private(set) var panel = SidebarPriorityPanel(entries: [])
    /// Redraws the working chips' elapsed time each minute while one shows; idle otherwise.
    private let ticker = DemandTimer(owner: "sidebar-priority-minute")
    /// The row being dragged: where in its slot the pointer grabbed it (document points from the slot's
    /// top) and the pointer's last window point, which an autoscroll frame replays.
    private struct RowDrag {
        let row: SidebarPriorityRowView
        let start: NSPoint
        let grab: CGFloat
        var windowPoint: NSPoint
    }
    private var rowDrag: RowDrag?
    /// Whether a row drag is in progress.
    var isDraggingRow: Bool { rowDrag != nil }
    /// Escape while a row is dragged cancels the drag: an app-local key monitor, installed when the drag
    /// starts and removed when it ends (`endRowDrag`), whichever way it ends.
    private var escapeMonitor: Any?
    /// Edge autoscroll while a row is dragged: frames from the window's FrameScheduler only while the
    /// pointer is in the list's top or bottom edge zone (`SidebarStyle.autoscrollZone`, as the main list).
    /// It stops when the pointer leaves the zone, the list reaches its end, the drag ends (drop) or the
    /// dragged row leaves, and when the panel leaves its window.
    private(set) lazy var autoscroll = FrameClient(owner: "SidebarPriority.autoscroll", view: self) { [weak self] tick in
        self?.autoscrollFrame(elapsed: tick.elapsed) ?? false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.onPress = { [weak self] in self.map { $0.onAction?(.setCollapsed(!$0.panel.collapsed)) } }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        document.passesThrough = { [weak self] view in self?.closing.contains { $0 === view } ?? false }
        SystemScrollers.followThin(scroll)
        empty.isHidden = true
        [header, count, fade, empty].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.priorityTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// The header's height and the rows' full height; the sidebar caps it (`height(maximum:)`).
    var headerHeight: CGFloat { SidebarDensityTokens.rowHeight }
    private var contentHeight: CGFloat {
        guard !panel.collapsed else { return 0 }
        guard !panel.entries.isEmpty else { return SidebarDensityTokens.rowHeight }
        return panel.entries.reduce(0) { $0 + SidebarPriorityRowView.height(hasPreview: $1.preview != nil) }
    }

    /// The height the panel takes, at most `maximum` (its rows then scroll inside).
    func height(maximum: CGFloat) -> CGFloat {
        min(headerHeight + contentHeight + Metrics.space1, max(headerHeight, maximum))
    }

    func show(_ panel: SidebarPriorityPanel) {
        // Folded, the panel shows no rows: a drag in progress ends there (its rows go back to their slots
        // before the new feed places them).
        if panel.collapsed { endRowDrag(cancelled: true) }
        let old = self.panel
        self.panel = panel
        header.configure(title: Strings.priorityTitle, collapsed: panel.collapsed)
        let attention = panel.attentionCount
        count.stringValue = panel.collapsed && attention > 0 ? String(attention) : ""
        empty.isHidden = panel.collapsed || !panel.entries.isEmpty
        fade.isHidden = panel.collapsed
        placeRows(animated: window != nil && old.entries != panel.entries)
        updateTicker()
        if old.collapsed != panel.collapsed || old.entries.count != panel.entries.count
            || old.entries.map({ $0.preview != nil }) != panel.entries.map({ $0.preview != nil }) {
            onHeightChange?()
        }
        needsLayout = true
    }

    /// Lays the rows out in rank order on the sidebar's motion (`Motion.sidebar`, the main list's `.move`
    /// spring), as the main list does (`RowMotion`, `SidebarRowTransition`): a row that moved slides
    /// there, a new row opens its slot from zero height at the top of its run of new rows, and a row
    /// that left closes its slot at the top of its run, so the rows below slide up into it. With motion
    /// off (the master switch, the sidebar switch, speed "off", Reduce Motion) all of it lands at once.
    private func placeRows(animated: Bool) {
        let width = scroll.contentView.bounds.width
        let oldFrames = rows.mapValues(\.frame)
        var targets: [(SidebarPriorityRowView, NSRect)] = [], opening: [(SidebarPriorityRowView, NSRect)] = []
        let shown = Set(panel.entries.map(\.id))
        var leaving: [(SidebarPriorityRowView, NSRect)] = []
        var runTop: CGFloat?
        for (id, frame) in oldFrames.sorted(by: { $0.value.minY < $1.value.minY }) {
            guard !shown.contains(id), let row = rows.removeValue(forKey: id) else { runTop = nil; continue }
            let top = runTop ?? frame.minY
            runTop = top
            row.onAction = nil
            row.onDrag = nil
            if rowDrag?.row === row { endRowDrag(cancelled: true) }
            opensUntil[ObjectIdentifier(row)] = nil
            leaving.append((row, NSRect(x: frame.minX, y: top, width: frame.width, height: 0)))
        }
        var y: CGFloat = 0
        runTop = nil
        for entry in panel.entries {
            let height = SidebarPriorityRowView.height(hasPreview: entry.preview != nil)
            let frame = NSRect(x: 0, y: y, width: width, height: height)
            if let row = rows[entry.id] {
                if row.entry != entry { row.configure(entry) }
                targets.append((row, frame))
                runTop = nil
            } else {
                let row = SidebarPriorityRowView(entry: entry)
                row.onAction = { [weak self] action in self?.onAction?(action) }
                row.onDrag = { [weak self] row, start, point, ended in self?.drag(row, start: start, point: point, ended: ended) }
                document.addSubview(row)
                rows[entry.id] = row
                let top = runTop ?? y
                runTop = top
                row.frame = NSRect(x: 0, y: top, width: width, height: 0)
                opening.append((row, frame))
            }
            y += height
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
        // A row being dragged stays under the pointer: the others take their places around it, and it
        // is laid out as a pointer move would lay it out (`holdDraggedRow`), in document points.
        if let held = rowDrag?.row { targets.removeAll { $0.0 === held } }
        defer { holdDraggedRow() }
        guard animated, Motion.sidebar.animatesMovement else {
            // Each row at its place, whole. Set through the animator, the frame replaces a move still in
            // flight (as `RowMotion` does), which a plain set would not stop.
            Motion.withoutAnimation {
                for (row, frame) in targets + opening {
                    row.animator().frame = frame
                    row.animator().alphaValue = 1
                    row.clipsToBounds = false
                }
            }
            for row in closing + leaving.map(\.0) { row.removeFromSuperview() }
            closing = []
            opensUntil = [:]
            return
        }
        closing += leaving.map(\.0)
        placement += 1
        let current = placement
        // A new row opens on this move; one still opening from an earlier move keeps opening on it. A
        // settled row whose preview made it taller also clips until its slot has grown: layout places
        // the full preview immediately while the row's frame is still on the spring.
        let opens = opening.map(\.0) + targets.filter { row, frame in
            opensUntil[ObjectIdentifier(row)] != nil || abs(row.frame.height - frame.height) > 0.5
        }.map(\.0)
        for row in opens { opensUntil[ObjectIdentifier(row)] = current }
        Motion.withoutAnimation {
            for row in opens { row.clipsToBounds = true }
            for (row, _) in leaving { row.clipsToBounds = true }
            for (row, _) in opening { row.alphaValue = 0 }
        }
        let gone = leaving.map(\.0)
        Motion.sidebar.animate(.move, in: self, {
            for (row, frame) in targets + opening {
                row.animator().frame = frame
                row.animator().alphaValue = 1
            }
            for (row, end) in leaving {
                row.animator().frame = end
                row.animator().alphaValue = 0
            }
        }, settleAtSleep: { [weak self] in self?.placeRows(animated: false) }, completion: { [weak self, opens, gone] in
            for row in gone { row.removeFromSuperview() }
            guard let self else { return }
            self.closing.removeAll { row in gone.contains { $0 === row } }
            // A row whose open a later move took over keeps clipping until that move ends.
            for row in opens where self.opensUntil[ObjectIdentifier(row)] == current {
                self.opensUntil[ObjectIdentifier(row)] = nil
                row.clipsToBounds = false
            }
        })
    }

    /// The row follows the pointer over the others; released, it takes the slot its middle is in
    /// (past the middle of a row it passed), the view shows that order at once and the App keeps it.
    /// A drop back in its own slot changes nothing. The pointer is read in the document's coordinates
    /// (through the clip view's scrolled bounds), so a list scrolled during the drag drops where the
    /// row shows; held at the list's top or bottom edge, the list scrolls (`autoscroll`).
    private func drag(_ row: SidebarPriorityRowView, start: NSPoint, point: NSPoint, ended: Bool) {
        guard let from = panel.entries.firstIndex(where: { $0.id == row.entry.id }) else { return endRowDrag(cancelled: true) }
        // A new press starts a new drag; its grab is read before anything scrolls.
        if rowDrag?.row !== row || rowDrag?.start != start {
            if rowDrag != nil { endRowDrag(cancelled: true) }
            rowDrag = RowDrag(row: row, start: start, grab: document.convert(start, from: nil).y - slotTop(from), windowPoint: point)
            observeEscape()
        }
        rowDrag?.windowPoint = point
        guard ended else {
            moveDraggedRow(from: from)
            if autoscrollVelocity(windowPoint: point) != 0 { autoscroll.activate() } else { autoscroll.deactivate() }
            return
        }
        // Released beside the panel (left or right of it), the drag is cancelled; above or below it, the
        // row drops at the end it was pulled to.
        let local = convert(point, from: nil)
        guard local.x >= bounds.minX, local.x <= bounds.maxX else { return endRowDrag(cancelled: true) }
        let slot = dropSlot(from: from)
        endRowDrag(cancelled: false)
        var order = panel.entries
        let entry = order.remove(at: from)
        order.insert(entry, at: slot)
        guard slot != from else { return placeRows(animated: window != nil) }
        panel.entries = order
        placeRows(animated: window != nil)
        onAction?(.place(entry.id, order: order.map(\.id)))
    }

    private var rowHeights: [CGFloat] { panel.entries.map { SidebarPriorityRowView.height(hasPreview: $0.preview != nil) } }
    private func slotTop(_ index: Int) -> CGFloat { rowHeights[..<index].reduce(0, +) }

    /// Where the dragged row's top is now, in document points: the pointer less its grab.
    private func draggedTop() -> CGFloat? {
        guard let drag = rowDrag else { return nil }
        return document.convert(drag.windowPoint, from: nil).y - drag.grab
    }

    /// The slot the dragged row's middle is in.
    private func dropSlot(from: Int) -> Int {
        let heights = rowHeights
        guard let top = draggedTop() else { return from }
        let middle = top + heights[from] / 2
        var slot = 0, y: CGFloat = 0
        for (index, height) in heights.enumerated() {
            if index != from, y + height / 2 < middle { slot += 1 }
            y += height
        }
        return slot
    }

    /// The dragged row's frame: its top under the pointer (the press keeps its place in the row), its size
    /// from the current layout, so a feed update that adds or drops its preview mid-drag resizes it as the
    /// drop math (`dropSlot`) already counts it.
    private func moveDraggedRow(from: Int) {
        guard let drag = rowDrag, let top = draggedTop() else { return }
        let heights = rowHeights
        let total = heights.reduce(0, +)
        let frame = NSRect(x: 0, y: min(max(0, top), max(0, total - heights[from])),
                           width: scroll.contentView.bounds.width, height: heights[from])
        Motion.withoutAnimation {
            drag.row.layer?.zPosition = 1
            drag.row.animator().frame = frame
        }
    }

    /// After the rows were placed (a feed update mid-drag), the dragged row goes back under the
    /// pointer's last point, as the next pointer move would put it.
    private func holdDraggedRow() {
        guard let drag = rowDrag else { return }
        guard let from = panel.entries.firstIndex(where: { $0.id == drag.row.entry.id }) else { return endRowDrag(cancelled: true) }
        moveDraggedRow(from: from)
    }

    /// The one way a row drag ends, however it ends: a drop (`cancelled` false; the caller places the
    /// rows in their new order), or a cancel (Escape, a release beside the panel, the dragged chat leaving
    /// the feed, the panel folding, hiding or leaving its window). Either way the autoscroll and the Escape
    /// monitor stop, the row forgets its press (a cancelled press's release opens nothing), drops back to
    /// its layer, and the hover is read again from the pointer. A cancel puts every row at its ranked slot.
    private func endRowDrag(cancelled: Bool) {
        autoscroll.deactivate()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        guard let drag = rowDrag else { return }
        rowDrag = nil
        drag.row.cancelPress()
        drag.row.layer?.zPosition = 0
        // A row that left the feed is already closing its slot (`placeRows` removed it).
        if cancelled, rows[drag.row.entry.id] === drag.row {
            placeRows(animated: window != nil && !isHiddenOrHasHiddenAncestor)
        }
        PointerHover.refresh(in: window)
    }

    private func observeEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.rowDrag != nil else { return event } // 53: Escape
            self.endRowDrag(cancelled: true)
            return nil
        }
    }

    /// Scroll speed for the pointer at `windowPoint` (points per second, negative up): zero outside the
    /// list's edge zones, up to ~25 rows a second at the edge (`SidebarAutoscroll`, as the main list).
    private func autoscrollVelocity(windowPoint: NSPoint) -> CGFloat {
        let clip = scroll.contentView
        guard document.frame.height > clip.bounds.height else { return 0 }
        let point = clip.convert(windowPoint, from: nil)
        return SidebarAutoscroll.velocity(pointY: point.y, visibleMinY: clip.bounds.minY, visibleMaxY: clip.bounds.maxY,
                                          zone: SidebarStyle.autoscrollZone, maxSpeed: Metrics.sidebarRowHeight * 25)
    }

    /// One autoscroll frame: scrolls by the edge speed over `elapsed` seconds and moves the dragged row
    /// with the list. False (the client goes idle) with no drag, outside the edge zones or at the list's end.
    func autoscrollFrame(elapsed: Double) -> Bool {
        guard let drag = rowDrag, let from = panel.entries.firstIndex(where: { $0.id == drag.row.entry.id }) else {
            return false
        }
        let velocity = autoscrollVelocity(windowPoint: drag.windowPoint)
        guard velocity != 0 else { return false }
        let clip = scroll.contentView, b = clip.bounds
        let y = min(max(b.minY + velocity * elapsed, 0), max(0, document.frame.height - b.height))
        guard y != b.minY else { return false }
        clip.scroll(to: NSPoint(x: b.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        moveDraggedRow(from: from)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endRowDrag(cancelled: true) }
    }

    override func viewDidHide() {
        super.viewDidHide()
        endRowDrag(cancelled: true)
    }

    /// A chip says minutes: one redraw a minute while a row works, none otherwise.
    private func updateTicker() {
        let working = !panel.collapsed && panel.entries.contains { if case .working = $0.state { true } else { false } }
        guard working else { return ticker.cancel() }
        ticker.scheduleIfIdle(after: .seconds(60)) { @MainActor [weak self] in
            guard let self else { return }
            for row in self.rows.values { row.tick(now: Date()) }
            self.updateTicker()
        }
    }

    override func layout() {
        super.layout()
        let b = bounds, inset = SidebarStyle.horizontalInset
        header.frame = NSRect(x: 0, y: 0, width: b.width, height: headerHeight)
        count.font = SidebarStyle.badgeFont
        let size = count.naturalSize
        // Left of the header's chevron, which shows while folded.
        count.frame = NSRect(x: b.width - inset * 2 - Metrics.smallIconSize - Metrics.space2 - size.width,
                             y: (headerHeight - size.height) / 2, width: size.width, height: size.height)
        let body = NSRect(x: 0, y: headerHeight, width: b.width, height: max(0, b.height - headerHeight - Metrics.space1))
        fade.frame = body
        empty.font = SidebarStyle.subtitleFont
        let emptySize = empty.naturalSize
        empty.frame = NSRect(x: inset, y: body.minY + (SidebarDensityTokens.rowHeight - emptySize.height) / 2,
                             width: max(0, b.width - 2 * inset), height: emptySize.height)
        if document.frame.width != scroll.contentView.bounds.width { placeRows(animated: false) }
    }

    override func updateLayer() {
        performWithTheme {
            count.textColor = Palette.attention
            empty.textColor = Palette.textTertiary
        }
    }
    nonisolated override var wantsUpdateLayer: Bool { true }

    /// Rows lay out top down. A row `passesThrough` says takes no clicks: the row under it (or the
    /// document) gets them.
    private final class FlippedDocument: NSView {
        var passesThrough: (NSView) -> Bool = { _ in false }

        nonisolated override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, let superview else { return super.hitTest(point) }
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            for child in subviews.reversed() where !passesThrough(child) {
                if let hit = child.hitTest(local) { return hit }
            }
            return self
        }
    }
}
