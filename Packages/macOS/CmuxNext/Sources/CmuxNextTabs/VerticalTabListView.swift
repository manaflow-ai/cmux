public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// A pane's tabs as a vertical column (`tabs.barPosition` left or right; a prototype, user
/// 2026-10-27): one row per tab in display order (pinned first), the selected row filled, a + at the
/// bottom. It reads the same ``TabStripModel`` as ``TabStripView`` and sends the same
/// ``TabStripIntent``s, so selection, close and new tab take the App's one path. Not yet: drag
/// reorder, groups' chips, hover cards and the tab menu (the horizontal strip keeps those).
public final class VerticalTabListView: NSView {
    /// The column's width in points.
    public static let preferredWidth: CGFloat = 200

    private let model: TabStripModel
    private let scrollView = NSScrollView()
    private let rowsView = FlippedRowsView()
    private let newTabButton = NSButton()
    private var rows: [VerticalTabRowView] = []
    private var observation: Task<Void, Never>?
    /// Room left at the top for the pane's buttons (the pane lays them over the column).
    public var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }

    /// The tabs the column shows, in order.
    public var rowIDs: [TabID] { rows.map(\.item.id) }
    /// The tab whose row is selected.
    public var selectedRowID: TabID? { rows.first(where: \.isSelected)?.item.id }

    public init(model: TabStripModel) {
        self.model = model
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = rowsView
        addSubview(scrollView)
        newTabButton.isBordered = false
        newTabButton.bezelStyle = .regularSquare
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: Strings.axNewTab)
        newTabButton.imagePosition = .imageOnly
        newTabButton.toolTip = Strings.axNewTab
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        addSubview(newTabButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(Strings.axStrip)
        syncFromModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated public override var isFlipped: Bool { true }

    /// Follows the model while the column is in a window, and stops when it leaves, so a hidden
    /// pane's column does no work. The task holds the column weakly and ends at the first change
    /// after the column is gone.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation?.cancel()
        observation = nil
        guard window != nil else { return }
        let model = model
        observation = Task { [weak self] in
            for await _ in ObservationStream({ Snapshot(tabs: model.orderedTabs, selectedID: model.selectedID) }) {
                guard let self else { return }
                self.syncFromModel()
            }
        }
    }

    /// Makes the rows match the model: reuses each tab's row, adds and drops rows, marks the
    /// selected one.
    public func syncFromModel() {
        let tabs = model.orderedTabs, selected = model.selectedID
        var reusable = Dictionary(rows.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = tabs.map { item in
            let row = reusable.removeValue(forKey: item.id) ?? makeRow(item)
            row.update(item, selected: item.id == selected)
            return row
        }
        reusable.values.forEach { $0.removeFromSuperview() }
        for row in rows where row.superview !== rowsView { rowsView.addSubview(row) }
        needsLayout = true
    }

    /// Selects `id`'s tab, as a click on its row does.
    public func activateRow(_ id: TabID) {
        model.send(.select(id))
    }

    private func makeRow(_ item: TabItem) -> VerticalTabRowView {
        let row = VerticalTabRowView(item: item)
        let id = item.id
        row.onActivate = { [weak self] in self?.activateRow(id) }
        row.onClose = { [weak self] source in self?.model.send(.close(id, source: source)) }
        return row
    }

    @objc private func newTabClicked() {
        model.send(.newTab(after: nil))
    }

    public override func layout() {
        super.layout()
        let inset = Metrics.space1, rowHeight = Metrics.iconSize + 2 * Metrics.space2
        let button = model.showsNewTabButton ? rowHeight : 0
        newTabButton.isHidden = button == 0
        newTabButton.frame = NSRect(x: inset, y: bounds.height - button - inset, width: bounds.width - 2 * inset, height: button)
        scrollView.frame = NSRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset - button - inset))
        let width = scrollView.contentSize.width
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: inset, y: inset + CGFloat(index) * (rowHeight + inset / 2), width: width - 2 * inset, height: rowHeight)
        }
        rowsView.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, (rows.last?.frame.maxY ?? 0) + inset))
        performWithTheme { newTabButton.contentTintColor = Palette.textSecondary }
    }

    private struct Snapshot: Equatable, Sendable {
        var tabs: [TabItem]
        var selectedID: TabID?
    }
}

/// The scroll view's document: rows from the top.
private final class FlippedRowsView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
