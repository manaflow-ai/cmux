import AppKit
import CmuxNextDesign
import CmuxNextCompat

/// The result list: an `NSTableView` with reused row views. Only visible
/// rows exist. Results reload in place without animation (no flicker);
/// selection and hover update just the affected row views.
final class PaletteListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    enum DisplayRow {
        case header(String)
        case item(PaletteRow)
    }

    var onHover: ((String?) -> Void)?
    /// The pointer moved over the list (hover after a real mouse move, not a scroll).
    var onPointerMove: ((String?) -> Void)?
    var onActivate: ((String) -> Void)?
    /// A middle-click on a row: close it, as Cmd-W does (Tab Search: the row's tab).
    var onMiddleClick: ((String) -> Void)?

    private let table = PaletteTableView()
    /// The row a middle press went down on (`onMiddleClick`).
    private var middlePressID: String?
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
        table.onMouseMoved = { [weak self] point in self?.updateHover(at: point, pointerMoved: true) }
        table.onMouseExited = { [weak self] in self?.onHover?(nil) }
        table.onClick = { [weak self] row in self?.activate(row: row) }
        // The press holds the row's id, not its index: a search that lands before the release may put another
        // row at that index, and the release then closes nothing.
        table.onMiddleDown = { [weak self] row in self?.middlePressID = self?.itemID(at: row) }
        table.onMiddleClick = { [weak self] row in
            guard let self, let id = itemID(at: row), id == middlePressID else { return }
            middlePressID = nil
            onMiddleClick?(id)
        }
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        // queue: .main runs inline for the clip view's post on main (scroll order kept).
        boundsObserver = MainActorObservation(NSView.boundsDidChangeNotification, object: contentView) { [weak self] in
            self?.boundsChanged()
        }
        scrollFit = ScrollFitElasticity(scrollView: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var boundsObserver: MainActorObservation?

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
        syncTableSelection()
        // Size the table now, not at the next display, so the rubber band
        // matches the new results before the next scroll event.
        table.tile()
    }

    func setSelection(_ id: String?) {
        let old = selectedID
        selectedID = id
        refresh(old)
        refresh(id)
        syncTableSelection()
    }

    /// The table's own selection follows the palette's, so VoiceOver reads and announces the
    /// selected row (cx-9ce.44). Nothing draws it (`selectionHighlightStyle` is `.none`), and
    /// clicks never select (`shouldSelectRow`): the search field keeps the keyboard.
    private func syncTableSelection() {
        let rows = selectedID.flatMap { rowIndexByID[$0] }.map { IndexSet(integer: $0) } ?? IndexSet()
        if table.selectedRowIndexes != rows { table.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    func setHover(_ id: String?) {
        let old = hoveredID
        hoveredID = id
        // Moving from one row to the next retargets at once, with no fade gap; only entering the
        // list and leaving it fade.
        let animated = old == nil || id == nil
        refresh(old, hoverAnimated: animated)
        refresh(id, hoverAnimated: animated)
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

    private func refresh(_ id: String?, hoverAnimated: Bool = true) {
        guard let id, let row = rowIndexByID[id] else { return }
        if let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? PaletteTableRowView {
            rowView.isPaletteSelected = id == selectedID
            rowView.setHovered(id == hoveredID, animated: hoverAnimated)
        }
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaletteRowCell)?.setSelected(id == selectedID)
    }

    // MARK: Mouse

    private func boundsChanged() {
        // Scrolling moves rows under a still pointer; re-hit-test so hover
        // follows the pointer, not the row it was over before the scroll.
        guard let window else { return }
        let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if table.visibleRect.contains(point) { updateHover(at: point) }
    }

    private func updateHover(at point: NSPoint, pointerMoved: Bool = false) {
        let row = table.row(at: point)
        let id: String? = if rows.indices.contains(row), case .item(let item) = rows[row] { item.id } else { nil }
        if pointerMoved, let onPointerMove { onPointerMove(id) } else { onHover?(id) }
    }

    private func itemID(at row: Int) -> String? {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
        return item.id
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
/// reports pointer movement and clicks by row. A click runs its row on the press;
/// a middle-click closes its row on the release over the row it went down on, as
/// the tab strip's does.
final class PaletteTableView: NSTableView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onClick: ((Int) -> Void)?
    var onMiddleDown: ((Int) -> Void)?
    var onMiddleClick: ((Int) -> Void)?
    /// The row a middle press went down on.
    private var middlePressRow: Int?
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

    /// A press runs the row under the pointer at once (Lawrence 2026-10-19: "mouse down to
    /// immediately open", Cmd+P rows included); the release runs nothing more. A press off every
    /// visible row (a row scrolled under the search bar or footer) runs nothing.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return }
        let index = row(at: point)
        guard index >= 0 else { return }
        let rect = rect(ofRow: index)
        onMouseMoved?(NSPoint(x: rect.midX, y: rect.midY))
        onClick?(index)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middlePressRow = visibleRow(at: event)
        if let middlePressRow { onMiddleDown?(middlePressRow) }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        defer { middlePressRow = nil }
        if let index = visibleRow(at: event), index == middlePressRow { onMiddleClick?(index) }
    }

    /// The visible row under `event`'s pointer, nil off every visible row.
    private func visibleRow(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return nil }
        let index = row(at: point)
        return index >= 0 ? index : nil
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
        let height = PaletteText.height(label)
        let x = PaletteLayout.listInset + Metrics.space4
        label.frame = pixelAligned(NSRect(x: x, y: Metrics.space1, width: bounds.width - 2 * x, height: height))
    }
}
