import AppKit
import CmuxNextDesign

/// The result list: an `NSTableView` with reused row views. Only visible
/// rows exist. Results reload in place without animation (no flicker);
/// selection and hover update just the affected row views.
final class PaletteListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    enum DisplayRow {
        case header(String)
        case item(PaletteRow)
    }

    var onHover: ((String?) -> Void)?
    var onActivate: ((String) -> Void)?

    private let table = PaletteTableView()
    private var rows: [DisplayRow] = []
    private var rowIndexByID: [String: Int] = [:]
    private var selectedID: String?
    private var hoveredID: String?
    /// No rubber band while every result fits.
    private var scrollFit: ScrollFitElasticity?

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        SystemScrollers.follow(self)
        automaticallyAdjustsContentInsets = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("palette.column"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.onMouseMoved = { [weak self] point in self?.updateHover(at: point) }
        table.onMouseExited = { [weak self] in self?.onHover?(nil) }
        table.onClick = { [weak self] row in self?.activate(row: row) }
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView
        )
        scrollFit = ScrollFitElasticity(scrollView: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Updates from the model

    func setSections(_ sections: [PaletteResultSection]) {
        var rows: [DisplayRow] = []
        var index: [String: Int] = [:]
        for section in sections {
            if !section.title.isEmpty { rows.append(.header(section.title)) }
            for row in section.rows {
                index[row.id] = rows.count
                rows.append(.item(row))
            }
        }
        self.rows = rows
        rowIndexByID = index
        table.reloadData()
        // Size the table now, not at the next display, so the rubber band
        // matches the new results before the next scroll event.
        table.tile()
    }

    func setSelection(_ id: String?) {
        let old = selectedID
        selectedID = id
        refresh(old)
        refresh(id)
    }

    func setHover(_ id: String?) {
        let old = hoveredID
        hoveredID = id
        refresh(old)
        refresh(id)
    }

    func scrollToSelection() {
        guard let id = selectedID, let row = rowIndexByID[id] else { return }
        // Keep the section header visible when selecting a section's first row.
        if row > 0, case .header = rows[row - 1] { table.scrollRowToVisible(row - 1) }
        table.scrollRowToVisible(row)
    }

    func relayoutRows() {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    private func refresh(_ id: String?) {
        guard let id, let row = rowIndexByID[id] else { return }
        if let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? PaletteTableRowView {
            rowView.isPaletteSelected = id == selectedID
            rowView.isHovered = id == hoveredID
        }
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaletteRowCell)?.setSelected(id == selectedID)
    }

    // MARK: Mouse

    @objc private func boundsChanged() {
        // Scrolling moves rows under a still pointer; re-hit-test so hover
        // follows the pointer, not the row it was over before the scroll.
        guard let window else { return }
        let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if table.visibleRect.contains(point) { updateHover(at: point) }
    }

    private func updateHover(at point: NSPoint) {
        let row = table.row(at: point)
        guard rows.indices.contains(row), case .item(let item) = rows[row] else {
            onHover?(nil)
            return
        }
        onHover?(item.id)
    }

    private func activate(row: Int) {
        guard rows.indices.contains(row), case .item(let item) = rows[row], item.item.isEnabled else { return }
        onActivate?(item.id)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return PaletteLayout.headerRowHeight }
        return PaletteLayout.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("palette.rowView")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? PaletteTableRowView ?? {
            let view = PaletteTableRowView()
            view.identifier = identifier
            return view
        }()
        if case .item(let item) = rows[row] {
            view.isPaletteSelected = item.id == selectedID
            view.isHovered = item.id == hoveredID
        } else {
            view.isPaletteSelected = false
            view.isHovered = false
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: PaletteSectionHeaderCell.identifier, owner: nil) as? PaletteSectionHeaderCell
                ?? PaletteSectionHeaderCell()
            cell.title = title
            return cell
        case .item(let item):
            let cell = tableView.makeView(withIdentifier: PaletteRowCell.identifier, owner: nil) as? PaletteRowCell
                ?? PaletteRowCell(frame: .zero)
            cell.configure(item, isSelected: item.id == selectedID)
            return cell
        }
    }
}

/// Table that never takes keyboard focus (the search field keeps it) and
/// reports pointer movement and clicks by row.
final class PaletteTableView: NSTableView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onClick: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onClick?(row) }
    }
}

/// Section title row.
final class PaletteSectionHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("palette.header")
    private let label = PaletteText.label(Typography.header, tone: .secondary)

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        let x = PaletteLayout.listInset + Metrics.space4
        label.frame = NSRect(x: x, y: Metrics.space1, width: bounds.width - 2 * x, height: height)
    }
}
