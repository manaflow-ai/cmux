import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The Priority view at the top of the sidebar, under the titlebar row: every agent chat ranked by
/// what needs the person (the App ranks them), a header that folds it to one line with a count, and
/// its own scroll past its share of the sidebar's height. When a chat's rank changes its row glides
/// to its new place on the sidebar's move spring; a new row fades in where it lands.
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
        SystemScrollers.follow(scroll)
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
        placeRows(animated: window != nil && old.entries.map(\.id) != panel.entries.map(\.id))
        updateTicker()
        if old.collapsed != panel.collapsed || old.entries.count != panel.entries.count
            || old.entries.map({ $0.preview != nil }) != panel.entries.map({ $0.preview != nil }) {
            onHeightChange?()
        }
        needsLayout = true
    }

    /// Lays the rows out in rank order. A row that moved glides there; a new one fades in.
    private func placeRows(animated: Bool) {
        let width = scroll.contentView.bounds.width
        var y: CGFloat = 0
        var targets: [(SidebarPriorityRowView, NSRect)] = [], appearing: [SidebarPriorityRowView] = []
        let shown = Set(panel.entries.map(\.id))
        for (id, row) in rows where !shown.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for entry in panel.entries {
            let height = SidebarPriorityRowView.height(hasPreview: entry.preview != nil)
            let frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
            if let row = rows[entry.id] {
                if row.entry != entry { row.configure(entry) }
                targets.append((row, frame))
            } else {
                let row = SidebarPriorityRowView(entry: entry)
                row.onAction = { [weak self] action in self?.onAction?(action) }
                row.frame = frame
                document.addSubview(row)
                rows[entry.id] = row
                appearing.append(row)
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
        guard animated, Motion.sidebar.animates(.newWorkspace) else {
            for (row, frame) in targets { row.frame = frame }
            return
        }
        for row in appearing { row.alphaValue = 0 }
        Motion.sidebar.animate(.move, in: self, {
            for (row, frame) in targets { row.animator().frame = frame }
            for row in appearing { row.animator().alphaValue = 1 }
        }, settleAtSleep: { [weak self] in self?.settleRows() })
    }

    /// Puts every row at its place now (the display slept mid-move).
    private func settleRows() {
        for row in rows.values { row.alphaValue = 1 }
        placeRows(animated: false)
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

    /// Rows lay out top down.
    private final class FlippedDocument: NSView {
        nonisolated override var isFlipped: Bool { true }
    }
}
