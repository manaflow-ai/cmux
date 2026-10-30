import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The Priority view at the top of the sidebar, under the titlebar row: every agent chat ranked by
/// what needs the person (the App ranks them), a header that folds it to one line with a count, and
/// its own scroll past its share of the sidebar's height. When a chat's rank changes its row slides
/// to its new place on the sidebar's move spring; a new row opens its slot and a leaving row closes its.
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
    private var rows: [String: SidebarPriorityRowView] = [:]
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
