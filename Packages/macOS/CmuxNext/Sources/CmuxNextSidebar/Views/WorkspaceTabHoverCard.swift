import AppKit
import CmuxNextDesign

/// Selectable inner tabs embedded in the workspace's rich preview, on the card's grid (Lawrence msg 19245):
/// each row's icon on the card's icon column, its text on the card's text column, every row one pitch
/// apart. The rows reach `WorkspaceTabHoverCardRow.fillOutset` past this view's edges (their hover fill),
/// so this view takes hits there too. Every tab is listed: `rowLimit` rows and one more show without
/// scrolling, a longer list shows `rowLimit` and a half rows and scrolls in place (Leo 2026-11-01: "the
/// show 1 more is reallly bad when it's this small like you need to be able to scroll through them").
@MainActor
final class WorkspaceTabHoverCardView: NSView, HoverCardInteractiveBody, HoverCardTextReporting {
    let style: WorkspaceTabHoverCardStyle
    /// The list, reaching `fillOutset` past this view's edges.
    private let container = WorkspaceTabHoverDocument()
    private let scrollView = NSScrollView()
    private let document = WorkspaceTabHoverDocument()
    private var rowViews: [WorkspaceTabHoverCardRow] = []
    /// The kind groups' labels (`style.groupsByKind`), reused.
    private var groupLabels: [ChromeLabel] = []
    /// The tabs in the order the list shows them (grouped by kind when the style groups).
    private var tabs: [SidebarTab] = []
    private var workspace = ""
    private var now = Date()
    private var selectedIndex = 0
    private var showsKeyboardSelection = false
    var onSelect: ((TabID) -> Void)?

    var reportedLines: [String] { rowViews.prefix(tabs.count).map(\.reportedLine) }
    override var isFlipped: Bool { true }

    init(style: WorkspaceTabHoverCardStyle = .standard) {
        self.style = style
        super.init(frame: .zero)
        isHidden = true
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScrollElasticity = .none
        SystemScrollers.followThin(scrollView)
        container.addSubview(scrollView)
        addSubview(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, tabs: [SidebarTab], now: Date = Date()) {
        let ordered = style.groupsByKind ? Self.grouped(tabs) : tabs
        let changed = workspace != title || self.tabs.map(\.id) != ordered.map(\.id)
        let selected = self.tabs.indices.contains(selectedIndex) ? self.tabs[selectedIndex].id : nil
        if changed { showsKeyboardSelection = false }
        workspace = title
        self.tabs = ordered
        self.now = now
        isHidden = tabs.isEmpty
        selectedIndex = selected.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        updateRows()
        if changed { scrollView.contentView.scroll(to: .zero) }
    }

    // MARK: Layout

    /// One line of the list: a kind group's label, or a tab (its index in `tabs`).
    private enum Item: Equatable {
        case group(String)
        case tab(Int)
    }

    private func items(upTo count: Int) -> [Item] {
        var out: [Item] = []
        var group: String?
        for index in 0..<min(count, tabs.count) {
            if style.groupsByKind {
                let name = Self.groupName(tabs[index].kind)
                if name != group { out.append(.group(name)) }
                group = name
            }
            out.append(.tab(index))
        }
        return out
    }

    /// One pitch for every tab row (Lawrence msg 19245: "row spacing is uneven"); a group label is its own line.
    private var rowPitch: CGFloat { style.rowHeight + Metrics.space1 }
    private var groupHeight: CGFloat { ceil(Typography.caption.ascender - Typography.caption.descender) + Metrics.space3 }

    private func height(of items: [Item]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(CGFloat(0)) { total, item in
            if case .tab = item { return total + rowPitch }
            return total + groupHeight
        }
        return sum - Metrics.space1
    }

    /// The scroll area's height: the whole list up to `rowLimit` and one more tabs, else `rowLimit` and a
    /// half rows, so the cut row says the list scrolls.
    private var listHeight: CGFloat {
        let all = height(of: items(upTo: tabs.count))
        guard tabs.count > style.rowLimit + 1 else { return all }
        return min(all, (CGFloat(style.rowLimit) + 1.5) * rowPitch - Metrics.space1)
    }

    override var intrinsicContentSize: NSSize {
        // As wide as the widest row's title and whole detail line (the card caps it at its max width).
        let rows = rowViews.prefix(tabs.count).map { $0.preferredWidth - 2 * WorkspaceTabHoverCardRow.fillOutset }
        return NSSize(width: rows.max() ?? 0, height: listHeight)
    }

    private func updateRows() {
        let count = tabs.count
        while rowViews.count < count {
            let row = WorkspaceTabHoverCardRow(style: style)
            row.onRelease = { [weak self, weak row] in
                guard let self, let row, let index = self.rowViews.firstIndex(where: { $0 === row }),
                      index < self.tabs.count else { return }
                self.selectedIndex = index
                self.updateSelection()
                self.onSelect?(self.tabs[index].id)
            }
            document.addSubview(row)
            rowViews.append(row)
        }
        for index in rowViews.indices {
            rowViews[index].isHidden = index >= count
            if index < count { rowViews[index].configure(tabs[index], now: now) }
        }
        let groups = items(upTo: count).compactMap { item -> String? in
            if case let .group(name) = item { return name }
            return nil
        }
        while groupLabels.count < groups.count {
            let label = ChromeLabel(labelWithString: "")
            label.font = Typography.caption
            document.addSubview(label)
            groupLabels.append(label)
        }
        for (index, label) in groupLabels.enumerated() {
            label.isHidden = index >= groups.count
            if index < groups.count { label.stringValue = groups[index] }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        updateSelection()
        applyColors()
    }

    override func layout() {
        super.layout()
        let outset = WorkspaceTabHoverCardRow.fillOutset
        let width = bounds.width + 2 * outset
        container.frame = CGRect(x: -outset, y: 0, width: width, height: bounds.height)
        let list = listHeight
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: list)
        // The legacy scroller takes its width from the content; an overlay scroller takes none.
        let contentWidth = NSScrollView.contentSize(forFrameSize: NSSize(width: width, height: list), horizontalScrollerClass: nil,
                                                    verticalScrollerClass: scrollView.hasVerticalScroller ? NSScroller.self : nil,
                                                    borderType: scrollView.borderType, controlSize: .regular,
                                                    scrollerStyle: scrollView.scrollerStyle).width
        let shown = items(upTo: tabs.count)
        document.frame = CGRect(x: 0, y: 0, width: contentWidth, height: height(of: shown))
        var y: CGFloat = 0
        var group = 0
        let textX = outset + WorkspaceHoverCardView.textInset
        for item in shown {
            switch item {
            case let .tab(index):
                rowViews[index].frame = CGRect(x: 0, y: y, width: contentWidth, height: style.rowHeight)
                rowViews[index].layoutSubtreeIfNeeded()
                y += rowPitch
            case .group:
                let label = groupLabels[group]
                let size = label.naturalSize
                let pad = label.alignmentRectInsets.left
                label.frame = CGRect(x: textX - pad, y: y + groupHeight - size.height - Metrics.space1,
                                     width: min(size.width, contentWidth - textX + pad), height: size.height)
                group += 1
                y += groupHeight
            }
        }
    }

    /// The rows' fill reaches past this view's edges: a point there is still the list's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.insetBy(dx: -WorkspaceTabHoverCardRow.fillOutset, dy: 0).contains(point) else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        for view in subviews.reversed() where !view.isHidden {
            if let hit = view.hitTest(local) { return hit }
        }
        return frame.contains(point) ? self : nil
    }

    func applyColors() {
        performWithTheme {
            for label in groupLabels { label.textColor = Palette.textTertiary }
        }
        rowViews.forEach { $0.applyColors() }
    }

    func handleHoverCardKeyDown(_ event: NSEvent) -> Bool {
        guard !tabs.isEmpty, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 125: moveSelection(by: 1)
        case 126: moveSelection(by: -1)
        case 36, 76:
            guard showsKeyboardSelection else { return false }
            onSelect?(tabs[selectedIndex].id)
        default: return false
        }
        return true
    }

    func acceptsHoverCardMouse(at screenPoint: CGPoint, in panel: NSWindow) -> Bool {
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let point = superview?.convert(windowPoint, from: nil) ?? windowPoint
        var hit = hitTest(point)
        while let view = hit {
            // The whole list (its gaps and scroller too) takes the pointer: a click or a wheel between two
            // rows never falls through and ends the card.
            if view is WorkspaceTabHoverCardRow || view === scrollView { return true }
            hit = view.superview
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        showsKeyboardSelection = true
        selectedIndex = (selectedIndex + delta + tabs.count) % tabs.count
        updateSelection()
        rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }

    private func updateSelection() {
        for (index, row) in rowViews.enumerated() where index < tabs.count {
            row.isKeyboardSelected = showsKeyboardSelection && index == selectedIndex
        }
    }

    /// `tabs` by kind group (agents, terminals, pages, other), each group in the tabs' own order.
    private static func grouped(_ tabs: [SidebarTab]) -> [SidebarTab] {
        tabs.enumerated().sorted { lhs, rhs in
            let a = groupRank(lhs.element.kind), b = groupRank(rhs.element.kind)
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }

    private static func groupRank(_ kind: SidebarTabKind) -> Int {
        switch kind {
        case .agentChat, .conversation: 0
        case .terminal, .remoteTerminal: 1
        case .browser: 2
        case .newTab, .other: 3
        }
    }

    private static func groupName(_ kind: SidebarTabKind) -> String {
        switch groupRank(kind) {
        case 0: Strings.hoverCardGroupAgents
        case 1: Strings.hoverCardGroupTerminals
        case 2: Strings.hoverCardGroupPages
        default: Strings.hoverCardGroupOther
        }
    }
}

/// The tab list's flipped containers (its outset frame and the scroll view's document).
private final class WorkspaceTabHoverDocument: NSView {
    override var isFlipped: Bool { true }
}
