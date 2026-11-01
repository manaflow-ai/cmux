import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// Selectable inner tabs embedded in the workspace's existing rich preview.
/// Every tab is listed; a list taller than `maxVisibleRows` scrolls in place, with half a row
/// showing at the bottom, instead of hiding tabs behind a "Show N more" (Leo 2026-11-01: "the
/// show 1 more is reallly bad when it's this small like you need to be able to scroll through
/// them").
@MainActor
final class WorkspaceTabHoverCardView: NSView, HoverCardInteractiveBody, HoverCardTextReporting {
    private let rowHeight: CGFloat
    private let maxVisibleRows: CGFloat
    private let showsFolder: Bool
    private let scrollView = NSScrollView()
    private let document = WorkspaceTabHoverDocument()
    private var listHeight: NSLayoutConstraint?
    private var rowViews: [WorkspaceTabHoverCardRow] = []
    private var tabs: [SidebarTab] = []
    private var workspace = ""
    private var selectedIndex = 0
    private var showsKeyboardSelection = false
    var onSelect: ((TabID) -> Void)?

    var reportedLines: [String] { rowViews.prefix(tabs.count).map(\.reportedLine) }
    private var stride: CGFloat { rowHeight + Metrics.space1 }
    private var documentHeight: CGFloat { max(0, CGFloat(tabs.count) * stride - Metrics.space1) }
    override var isFlipped: Bool { true }

    /// `rowLimit` rows, and one more, show without scrolling: one tab past a round number never
    /// scrolls. A longer list shows `rowLimit` and a half rows and scrolls.
    init(rowHeight: CGFloat = 36, rowLimit: Int = 4, showsFolder: Bool = true) {
        self.rowHeight = rowHeight
        maxVisibleRows = CGFloat(max(1, rowLimit)) + 1.5
        self.showsFolder = showsFolder
        super.init(frame: .zero)
        isHidden = true
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScrollElasticity = .none
        SystemScrollers.followThin(scrollView)
        let stack = NSStackView(views: [scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
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
        if changed { showsKeyboardSelection = false }
        workspace = title
        self.tabs = tabs
        isHidden = tabs.isEmpty
        selectedIndex = selected.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
        updateRows()
        if changed { scrollView.contentView.scroll(to: .zero) }
    }

    private func updateRows() {
        let count = tabs.count
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
        listHeight?.constant = min(documentHeight, maxVisibleRows * stride - Metrics.space1)
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
        document.frame = CGRect(x: 0, y: 0, width: width, height: documentHeight)
        for index in 0..<min(tabs.count, rowViews.count) {
            rowViews[index].frame = CGRect(x: 0, y: CGFloat(index) * stride, width: width, height: rowHeight)
        }
    }

    func applyColors() {
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
}

private final class WorkspaceTabHoverDocument: NSView {
    override var isFlipped: Bool { true }
}
