import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import CmuxVisibleRows

/// The Priority view at the top of the sidebar, under the titlebar row: every agent chat ranked by
/// what needs the person (the App ranks them), a header that folds it to one line with a count, and
/// its own scroll past its share of the sidebar's height. When a chat's rank changes its row slides
/// to its new place on the sidebar's move spring; a new row opens its slot and a leaving row closes its.
/// The person can drag a row to another place; it stays there (the App keeps it, `.place`), and the
/// other chats rank around it (Leo 2026-10-21). It lists every chat with no cap, so only the rows in
/// view and one viewport above and below exist (`drawnIndices`), at 100 chats as at 10,000 (Leo
/// 2026-11-18: "we draw the visible area, right?").
final class SidebarPriorityPanelView: NSView {
    var onAction: ((SidebarPriorityAction) -> Void)?
    /// The panel's height changed (rows came or went, it folded): the sidebar lays out again.
    var onHeightChange: (() -> Void)?

    private let header = SidebarSectionHeaderView()
    private let count = ChromeLabel(labelWithString: "")
    private let empty = ChromeLabel(labelWithString: Strings.priorityEmpty)
    /// The filter chips under the header while `panel.filters` is set (`sidebar.priorityView.filters`).
    let filterBar = SidebarPriorityFilterBarView()
    /// Mark All as Read at the header's trailing edge while the chips show and a row can be marked.
    let markAllRead = SidebarIconButton(symbol: "checkmark.circle", label: Strings.priorityMarkAllRead)
    private let scroll = OverlayScrollView()
    let clip = ScrollReportingClipView()
    private lazy var fade = ScrollEdgeFadeView(scrollView: scroll)
    let document = FlippedDocument()
    /// The drawn rows (`drawnIndices`), never one per chat.
    var rows: [String: SidebarPriorityRowView] = [:]
    /// The Archived fold under the rows (`panel.archived`): its header, the open fold's chat rows and its Show More.
    /// Folded it holds no chat row.
    let archivedHeader = SidebarSectionHeaderView()
    private(set) var archivedRows: [String: SidebarArchivedChatRowView] = [:]
    let archivedMore = SidebarArchivedChatRowView()
    /// Rows that left and still close their slot; they go when their move ends. They take no clicks
    /// (`FlippedDocument.hitTest`), so a right-click there opens no menu for a chat that left.
    private var closing: [SidebarPriorityRowView] = []
    /// The number of the last animated placement (`placeRows`), and for each row still opening its
    /// slot the placement whose end unclips it: a row whose slot changes again while it opens keeps
    /// clipping until the later move ends, as the main list's `opens` count does.
    private var placement = 0
    var opensUntil: [ObjectIdentifier: Int] = [:]
    /// Drawn rows ranked out of view, still sliding to their place: they go when the last move ends.
    var slidingOut: Set<String> = []
    private(set) var panel = SidebarPriorityPanel(entries: []) { didSet { reindex() } }
    /// Each row's top in rank order (`tops`: `panel.entries[i]` spans `tops[i]..<tops[i + 1]`) and each chat's place.
    var rowIndex = VisibleRowsIndex<String>()
    var tops: [CGFloat] { rowIndex.tops }
    var places: [String: Int] { rowIndex.places }
    /// `tops` and `places` at the last placement: a chat that ranks into view slides in from where it was.
    private var placed: (tops: [CGFloat], places: [String: Int]) = ([0], [:])
    let listWork = ListWorkMeter()
    /// Redraws the working chips' elapsed time each minute while one shows; idle otherwise.
    let ticker = DemandTimer(owner: "sidebar-priority-minute")
    private(set) var draggingID: String?
    /// The scroll position when the held row's drag began: scrolling while holding a row moves the
    /// pointer through the document, so the drag adds it to the pointer's window offset.
    private var dragScrollStart: CGFloat?
    /// The held row's last pointer offset (window points): a scroll with the pointer still moves the row again.
    var dragPointerOffset: CGFloat = 0
    /// Whether the left button is held now (`endReleasedGesture`). Tests inject an answer.
    var leftButtonIsDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Frames while a held row's pointer is in the list's top or bottom edge zone; idle otherwise
    /// (the release, a cancel, the pointer leaving the zone or the list reaching its end stops it).
    private(set) lazy var autoscrollClient = FrameClient(owner: "Sidebar.priority.autoscroll", view: self) { [weak self] tick in
        self?.autoscrollStep(elapsed: tick.frameElapsed) ?? false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.onPress = { [weak self] in self.map { $0.onAction?(.setCollapsed(!$0.panel.collapsed)) } }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        // A scroll while a row is held keeps the row under the pointer (`clipScrolled`).
        clip.onScroll = { [weak self] in self?.clipScrolled() }
        clip.onResize = { [weak self] in self?.realizeDrawnRows() }
        scroll.contentView = clip
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        document.passesThrough = { [weak self] view in self?.closing.contains { $0 === view } ?? false }
        archivedHeader.onPress = { [weak self] in
            guard let self else { return }
            self.onAction?(.setArchivedFolded(!self.panel.archived.folded))
        }
        archivedMore.onAction = { [weak self] action in self?.onAction?(action) }
        archivedHeader.isHidden = true
        archivedMore.isHidden = true
        document.addSubview(archivedHeader)
        document.addSubview(archivedMore)
        SystemScrollers.followThin(scroll, scrollOnly: true)
        empty.isHidden = true
        filterBar.isHidden = true
        filterBar.onAction = { [weak self] action in self?.onAction?(action) }
        markAllRead.isHidden = true
        markAllRead.setAccessibilityIdentifier("cmux.sidebar.priority.markAllRead")
        markAllRead.onPress = { [weak self] in self?.onAction?(.markAllRead) }
        [header, count, markAllRead, filterBar, fade, empty].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.priorityTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// The header's height and the rows' full height; the sidebar caps it (`height(maximum:)`).
    var headerHeight: CGFloat { SidebarDensityTokens.rowHeight }
    /// The header and, while they show, the filter chips: where the rows start.
    private var topHeight: CGFloat { headerHeight + (showsFilterBar ? SidebarPriorityFilterBarView.height : 0) }
    private var showsFilterBar: Bool { panel.filters != nil && !panel.collapsed }
    private var contentHeight: CGFloat {
        guard !panel.collapsed else { return 0 }
        return rowsHeight + Self.archivedHeight(panel.archived)
    }

    /// The ranked rows' height, or the empty line's.
    private var rowsHeight: CGFloat {
        guard !panel.entries.isEmpty else { return SidebarDensityTokens.rowHeight }
        return tops.last ?? 0
    }

    /// The Archived fold's height: nothing while no chat is archived, else its header, the open fold's rows and its
    /// Show More row.
    static func archivedHeight(_ archived: SidebarArchivedChats) -> CGFloat {
        guard archived.isVisible else { return 0 }
        let rows = archived.rows.count + (archived.hiddenCount > 0 ? 1 : 0)
        return CGFloat(1 + rows) * SidebarArchivedChatRowView.height
    }

    /// The height the panel takes, at most `maximum` (its rows then scroll inside).
    func height(maximum: CGFloat) -> CGFloat {
        min(topHeight + contentHeight + Metrics.space1, max(topHeight, maximum))
    }

    func show(_ panel: SidebarPriorityPanel) {
        let old = self.panel, oldTops = tops
        self.panel = panel; listWork.walked(panel.entries.count) // the compares below read every chat (`VisibleRowsBaseline`)
        // Hiding invalidates even a press below the drag threshold: its release may never reach
        // the hidden row. A re-rank, a fold or a height change also invalidates the press's slot.
        if old.shown != panel.shown || old.collapsed != panel.collapsed || oldTops != tops
            || !old.entries.elementsEqual(panel.entries, by: { $0.id == $1.id }) {
            stopPresses()
        }
        header.configure(title: Strings.priorityTitle, collapsed: panel.collapsed)
        let attention = panel.attentionCount
        count.stringValue = panel.collapsed && attention > 0 ? String(attention) : ""
        empty.isHidden = panel.collapsed || !panel.entries.isEmpty
        // A filter with no rows says so, not that there are no chats at all.
        empty.stringValue = (panel.filters?.selected ?? .all) == .all ? Strings.priorityEmpty : Strings.priorityFilterEmpty
        fade.isHidden = panel.collapsed
        filterBar.isHidden = !showsFilterBar
        if let filters = panel.filters { filterBar.show(filters) }
        markAllRead.isHidden = !showsFilterBar || (panel.filters?.markable ?? 0) == 0
        if old.statusWords != panel.statusWords {
            for row in rows.values { row.statusWords = panel.statusWords }
        }
        placeRows(animated: window != nil && old.entries != panel.entries)
        updateTicker()
        // `tops` holds every row's height, so a row that grew or a count that changed moves it.
        if old.collapsed != panel.collapsed || oldTops != tops || (old.filters == nil) != (panel.filters == nil)
            || Self.archivedHeight(old.archived) != Self.archivedHeight(panel.archived) {
            onHeightChange?()
        }
        needsLayout = true
    }

    /// Lays the drawn rows out in rank order on the sidebar's motion (`Motion.sidebar`, the main list's `.move`
    /// spring), as the main list does (`RowMotion`, `SidebarRowTransition`): a row that moved slides
    /// there, a new row opens its slot from zero height at the top of its run of new rows, and a row
    /// that left closes its slot at the top of its run, so the rows below slide up into it. A chat that ranks
    /// into view slides in from its old place; a drawn row that ranks out of view slides there and goes when
    /// its move ends. A row already at its slot is not set again. With motion off (the master switch, the
    /// sidebar switch, speed "off", Reduce Motion) all of it lands at once.
    func placeRows(animated: Bool) {
        let width = scroll.contentView.bounds.width
        let moves = animated && Motion.sidebar.animatesMovement(in: window)
        var targets: [(SidebarPriorityRowView, NSRect)] = [], opening: [(SidebarPriorityRowView, NSRect)] = []
        var leaving: [(SidebarPriorityRowView, NSRect)] = []
        var runTop: CGFloat?
        // Only drawn rows can leave: visit those, not every chat.
        for (id, row) in rows.sorted(by: { $0.value.frame.minY < $1.value.frame.minY }) {
            guard places[id] == nil, rows.removeValue(forKey: id) != nil else { runTop = nil; continue }
            let frame = row.frame, top = runTop ?? row.frame.minY
            runTop = top
            row.onAction = nil
            row.onDrag = nil
            opensUntil[ObjectIdentifier(row)] = nil
            leaving.append((row, NSRect(x: frame.minX, y: top, width: frame.width, height: 0)))
        }
        let drawn = drawnIndices()
        var kept = Set<String>()
        var previous: Int?
        runTop = nil
        for index in drawn {
            if let previous, index != previous + 1 { runTop = nil }
            previous = index
            let entry = panel.entries[index]
            let frame = slotFrame(index, width: width)
            kept.insert(entry.id)
            if let row = rows[entry.id] {
                if row.entry != entry { row.configure(entry); listWork.configured() }
                targets.append((row, frame))
                runTop = nil
            } else if let was = placed.places[entry.id], was + 1 < placed.tops.count {
                let row = mount(entry)
                row.frame = NSRect(x: 0, y: placed.tops[was], width: width, height: placed.tops[was + 1] - placed.tops[was])
                targets.append((row, frame))
                runTop = nil
            } else {
                let row = mount(entry)
                let top = runTop ?? frame.minY
                runTop = top
                row.frame = NSRect(x: 0, y: top, width: width, height: 0)
                opening.append((row, frame))
            }
        }
        // A drawn row ranked out of view: it slides to its place and goes when the move ends; with no move it goes now.
        slidingOut = []
        for (id, row) in rows where !kept.contains(id) {
            guard moves, let index = places[id] else { unmount(id); continue }
            slidingOut.insert(id)
            targets.append((row, slotFrame(index, width: width)))
        }
        let archivedTop = panel.entries.isEmpty ? SidebarDensityTokens.rowHeight : tops.last ?? 0
        document.frame = NSRect(x: 0, y: 0, width: width, height: archivedTop + Self.archivedHeight(panel.archived))
        placeArchived(top: archivedTop, width: width)
        placed = (tops, places)
        // The held row stays under the pointer while another chat's text updates: only a re-rank or a
        // height change moves it, and those cancel the drag first (`show`).
        if let held = draggingID.flatMap({ rows[$0] }) { targets.removeAll { $0.0 === held } }
        guard moves else {
            // Each row at its place, whole. Set through the animator, the frame replaces a move still in
            // flight (as `RowMotion` does), which a plain set would not stop.
            let landing = (targets + opening).filter { !Self.landed($0.0, at: $0.1) }
            Motion.withoutAnimation {
                for (row, frame) in landing {
                    row.animator().frame = frame
                    row.animator().alphaValue = 1
                    row.clipsToBounds = false
                }
            }
            for (row, frame) in landing { row.slot = frame }
            listWork.laidOut(landing.count)
            for row in closing + leaving.map(\.0) { row.removeFromSuperview() }
            closing = []
            opensUntil = [:]
            return
        }
        closing += leaving.map(\.0)
        placement += 1
        let current = placement
        // A row already headed to its slot is not moved again (one chat's change moves no other row).
        targets.removeAll { row, frame in row.slot == frame && row.alphaValue == 1 }
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
        for (row, frame) in targets + opening { row.slot = frame }
        listWork.laidOut(targets.count + opening.count)
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
            // The rows that slid out of view go; any the scroll revealed meanwhile come.
            if current == self.placement { self.slidingOut = [] }
            self.realizeDrawnRows()
        })
    }

    /// Lays out the Archived fold from `top`: its header "Archived (N)", then, open, the newest archives and Show More.
    /// It does not move on the rows' spring: it sits under them and moves with the document.
    private func placeArchived(top: CGFloat, width: CGFloat) {
        let archived = panel.archived, height = SidebarArchivedChatRowView.height
        archivedHeader.isHidden = !archived.isVisible || panel.collapsed
        archivedHeader.configure(title: Strings.archivedFold(archived.count), collapsed: archived.folded)
        archivedHeader.frame = NSRect(x: 0, y: top, width: width, height: height)
        let shown = Set(archived.rows.map(\.id))
        for (id, row) in archivedRows where !shown.contains(id) {
            row.removeFromSuperview()
            archivedRows[id] = nil
        }
        var y = top + height
        for chat in archived.rows {
            let row = archivedRows[chat.id] ?? {
                let row = SidebarArchivedChatRowView()
                row.onAction = { [weak self] action in self?.onAction?(action) }
                document.addSubview(row)
                archivedRows[chat.id] = row
                return row
            }()
            if row.chat != chat { row.configure(chat) }
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        archivedMore.isHidden = archived.hiddenCount == 0
        if archived.hiddenCount > 0 {
            archivedMore.configureShowMore(hidden: archived.hiddenCount)
            archivedMore.frame = NSRect(x: 0, y: y, width: width, height: height)
        }
    }

    /// The row follows the pointer over the others; released, it takes the slot its middle is in
    /// (past the middle of a row it passed), the view shows that order at once and the App keeps it.
    /// A drop back in its own slot changes nothing.
    func drag(_ row: SidebarPriorityRowView, offset: CGFloat, ended: Bool) {
        guard let from = places[row.entry.id], from < panel.entries.count, panel.entries[from].id == row.entry.id else { return }
        let top = tops[from], height = tops[from + 1] - top, total = tops.last ?? 0
        let scrollY = scroll.contentView.bounds.origin.y
        let scrollStart = dragScrollStart ?? scrollY
        let offset = offset + scrollY - scrollStart
        let middle = top + height / 2 + offset
        let slot = dropSlot(from: from, middle: middle)
        guard ended else {
            draggingID = row.entry.id
            dragScrollStart = scrollStart
            dragPointerOffset = offset - (scrollY - scrollStart)
            if let point = row.heldWindowPoint { updateAutoscroll(windowPoint: point) }
            Motion.withoutAnimation {
                row.layer?.zPosition = 1
                row.animator().frame.origin.y = min(max(0, top + offset), max(0, total - height))
            }
            row.slot = nil
            return
        }
        row.layer?.zPosition = 0
        draggingID = nil
        dragScrollStart = nil
        autoscrollClient.deactivate()
        var order = panel.entries
        let entry = order.remove(at: from)
        order.insert(entry, at: slot)
        guard slot != from else { return placeRows(animated: window != nil) }
        panel.entries = order
        placeRows(animated: window != nil)
        onAction?(.place(entry.id, order: order.map(\.id)))
    }

    func keyEventSeen(_ event: NSEvent) {
        guard event.keyCode == 53, owns(event.window) else { return }
        // Escape cancels both an active drag and a below-threshold press. The latter may otherwise
        // receive a stale mouseUp and open its row after the cancellation.
        endPointerGesture()
    }

    private func owns(_ eventWindow: NSWindow?) -> Bool {
        guard let eventWindow, let window else { return false }
        if eventWindow === window { return true }
        var parent = eventWindow.parent
        while let current = parent {
            if current === window { return true }
            parent = current.parent
        }
        return false
    }

    private func stopPresses() {
        for row in rows.values { row.cancelPress() }
        dragScrollStart = nil
        autoscrollClient.deactivate()
        guard let id = draggingID else { return }
        draggingID = nil
        rows[id]?.layer?.zPosition = 0
    }

    private func cancelDrag() {
        guard draggingID != nil else { return }
        stopPresses()
        placeRows(animated: window != nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endPointerGesture() }
    }

    /// Ends a held row or a pending press: a drag goes back to its slot, and a press opens nothing on its release.
    func endPointerGesture() {
        if draggingID != nil { cancelDrag() } else { stopPresses() }
    }

    /// A left press or release anywhere in the app, before its window gets it (the sidebar list's monitor). A press
    /// means an earlier release never came here (a menu or a modal took it); a release sent to another window ends
    /// the gesture after its dispatch, unless the button is still down or a forwarded release already ended it.
    func pointerEventSeen(_ type: NSEvent.EventType, in eventWindow: NSWindow?) {
        switch type {
        case .leftMouseDown:
            endPointerGesture()
        case .leftMouseUp where eventWindow !== window:
            Task { @MainActor [weak self] in
                guard let self, !self.leftButtonIsDown() else { return }
                self.endPointerGesture()
            }
        default:
            break
        }
    }

    /// The app lost focus: its eventual release is delivered to another app, even when AppKit still
    /// reports the button held at the notification. End the gesture immediately so the row cannot
    /// remain raised until another sidebar event.
    func pointerFocusLost() {
        endPointerGesture()
    }

    override func cancelOperation(_ sender: Any?) {
        endPointerGesture()
    }

    /// The list's scroll speed for a held row's pointer at `windowPoint`: zero outside its edge zones, up to about
    /// 25 rows a second at the very edge, as the main list scrolls (`SidebarDragAutoscroll`).
    private func autoscrollVelocity(windowPoint: NSPoint) -> CGFloat {
        let point = clip.convert(windowPoint, from: nil)
        let bounds = clip.bounds
        return SidebarAutoscroll.velocity(pointY: point.y, visibleMinY: bounds.minY, visibleMaxY: bounds.maxY,
                                          zone: SidebarStyle.autoscrollZone, maxSpeed: Metrics.sidebarRowHeight * 25)
    }

    /// Runs the edge autoscroll only while a row is held with its pointer in an edge zone.
    private func updateAutoscroll(windowPoint: NSPoint) {
        guard draggingID != nil, autoscrollVelocity(windowPoint: windowPoint) != 0 else { return autoscrollClient.deactivate() }
        autoscrollClient.activate()
    }

    /// One autoscroll frame of `elapsed` seconds; false once there is nothing to scroll. The scroll moves the
    /// held row with it (`clipScrolled`), as a scroll wheel under a held row does.
    func autoscrollStep(elapsed: Double) -> Bool {
        guard let id = draggingID, let point = rows[id]?.heldWindowPoint else { return false }
        let velocity = autoscrollVelocity(windowPoint: point)
        guard velocity != 0 else { return false }
        // A frame that shows no later than the last one (after a hang) moves nothing: keep ticking.
        guard elapsed > 0 else { return true }
        let bounds = clip.bounds
        let next = min(max(bounds.minY + velocity * elapsed, 0), max(0, document.frame.height - bounds.height))
        guard next != bounds.minY else { return false }
        clip.scroll(to: NSPoint(x: bounds.minX, y: next))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    func move(_ id: String, direction: SidebarPriorityRowView.MoveDirection) {
        guard draggingID == nil, let from = places[id] else { return }
        let to = direction == .earlier ? from - 1 : from + 1
        guard panel.entries.indices.contains(to) else { return }
        var order = panel.entries
        order.swapAt(from, to)
        panel.entries = order
        placeRows(animated: window != nil)
        onAction?(.place(id, order: order.map(\.id)))
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
        // Mark All as Read where the folded count sits (the two never show together).
        let button = Metrics.smallIconSize + Metrics.space2
        markAllRead.frame = NSRect(x: b.width - inset * 2 - Metrics.smallIconSize - Metrics.space2 - button,
                                   y: (headerHeight - button) / 2, width: button, height: button)
        let barHeight = showsFilterBar ? SidebarPriorityFilterBarView.height : 0
        filterBar.frame = NSRect(x: 0, y: headerHeight, width: b.width, height: barHeight)
        let body = NSRect(x: 0, y: topHeight, width: b.width, height: max(0, b.height - topHeight - Metrics.space1))
        fade.frame = body
        empty.font = SidebarStyle.subtitleFont
        let emptySize = empty.naturalSize
        empty.frame = NSRect(x: inset, y: body.minY + (SidebarDensityTokens.rowHeight - emptySize.height) / 2,
                             width: max(0, b.width - 2 * inset), height: emptySize.height)
        if document.frame.width != scroll.contentView.bounds.width { placeRows(animated: false) } else { realizeDrawnRows() }
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
    final class FlippedDocument: NSView {
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
