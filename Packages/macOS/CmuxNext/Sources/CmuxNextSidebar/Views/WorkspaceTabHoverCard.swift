import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// Selectable inner tabs embedded in the workspace's existing rich preview.
/// Overflow expands inside the same bounded scroll area; it never covers the history.
@MainActor
final class WorkspaceTabHoverCardView: NSView, HoverCardInteractiveBody, HoverCardTextReporting {
    private let rowHeight: CGFloat
    private let rowLimit: Int
    private let showsFolder: Bool
    private let scrollView = NSScrollView()
    private let document = WorkspaceTabHoverDocument()
    private let more = ClickableButton(title: "", target: nil, action: nil)
    private var listHeight: NSLayoutConstraint?
    private var rowViews: [WorkspaceTabHoverCardRow] = []
    private var tabs: [SidebarTab] = []
    private var workspace = ""
    private var expanded = false
    private var selectedIndex = 0
    private var showsKeyboardSelection = false
    var onSelect: ((TabID) -> Void)?
    var onResize: (() -> Void)?

    var reportedLines: [String] {
        rowViews.prefix(visibleCount).map { $0.reportedLine } + (more.isHidden ? [] : [more.title])
    }
    private var visibleCount: Int { expanded ? tabs.count : min(tabs.count, rowLimit) }
    override var isFlipped: Bool { true }

    init(rowHeight: CGFloat = 36, rowLimit: Int = 4, showsFolder: Bool = true) {
        self.rowHeight = rowHeight
        self.rowLimit = max(1, rowLimit)
        self.showsFolder = showsFolder
        super.init(frame: .zero)
        isHidden = true
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScrollElasticity = .none
        SystemScrollers.followThin(scrollView)
        more.isBordered = false
        more.font = Typography.caption
        more.alignment = .left
        more.target = self
        more.action = #selector(expandTabs)
        let stack = NSStackView(views: [scrollView, more])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        let height = scrollView.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        listHeight = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, tabs: [SidebarTab]) {
        let changed = workspace != title || self.tabs.map(\.id) != tabs.map(\.id)
        let selected = self.tabs.indices.contains(selectedIndex) ? self.tabs[selectedIndex].id : nil
        if changed { expanded = false; showsKeyboardSelection = false }
        workspace = title
        self.tabs = tabs
        isHidden = tabs.isEmpty
        selectedIndex = selected.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
        updateRows()
        if changed { scrollView.contentView.scroll(to: .zero) }
    }

    private func updateRows() {
        let count = visibleCount
        while rowViews.count < count {
            let row = WorkspaceTabHoverCardRow(height: rowHeight, showsFolder: showsFolder)
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
            if index < count { rowViews[index].configure(tabs[index]) }
        }
        let height = max(0, CGFloat(count) * (rowHeight + Metrics.space1) - Metrics.space1)
        listHeight?.constant = min(height, CGFloat(rowLimit) * (rowHeight + Metrics.space1) - Metrics.space1)
        more.title = Strings.showMore(max(0, tabs.count - count))
        more.isHidden = expanded || tabs.count <= rowLimit
        needsLayout = true
        updateSelection()
        applyColors()
    }

    override func layout() {
        super.layout()
        // The scroll view spans this view's width (its stack is pinned to our edges), but the
        // stack places it only after this pass: its frame here can still be the old (first pass:
        // zero) one, which gave every row zero width, so no click or hit test reached a row.
        let width = NSScrollView.contentSize(forFrameSize: NSSize(width: bounds.width, height: scrollView.frame.height),
                                             horizontalScrollerClass: nil,
                                             verticalScrollerClass: scrollView.hasVerticalScroller ? NSScroller.self : nil,
                                             borderType: scrollView.borderType, controlSize: .regular,
                                             scrollerStyle: scrollView.scrollerStyle).width
        document.frame = CGRect(x: 0, y: 0, width: width,
                                height: max(0, CGFloat(visibleCount) * (rowHeight + Metrics.space1) - Metrics.space1))
        for index in 0..<visibleCount {
            rowViews[index].frame = CGRect(x: 0, y: CGFloat(index) * (rowHeight + Metrics.space1), width: width, height: rowHeight)
        }
    }

    @objc private func expandTabs() {
        expanded = true
        updateRows()
        layoutSubtreeIfNeeded()
        onResize?()
    }

    func applyColors() {
        performWithTheme { more.contentTintColor = Palette.textSecondary }
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
            if view is WorkspaceTabHoverCardRow || view === more { return true }
            hit = view.superview
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        showsKeyboardSelection = true
        selectedIndex = (selectedIndex + delta + tabs.count) % tabs.count
        if selectedIndex >= visibleCount { expandTabs() }
        updateSelection()
        rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }

    private func updateSelection() {
        for (index, row) in rowViews.enumerated() where index < tabs.count {
            row.isKeyboardSelected = showsKeyboardSelection && index == selectedIndex
        }
    }
}

private final class WorkspaceTabHoverDocument: NSView {
    override var isFlipped: Bool { true }
}
