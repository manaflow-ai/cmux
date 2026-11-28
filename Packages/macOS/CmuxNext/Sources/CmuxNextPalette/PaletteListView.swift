import AppKit
import CmuxNextDesign
import CmuxNextCompat

/// The result list: an `NSTableView` with reused row views. Only visible
/// rows exist. New results update the rows on screen in place without
/// animation (no flicker, ``setSections(_:)``); selection and hover update
/// just the affected row views.
final class PaletteListView: OverlayScrollView, NSTableViewDataSource, NSTableViewDelegate {
    enum DisplayRow {
        case header(String)
        case item(PaletteRow)

        var isHeader: Bool {
            if case .header = self { return true }
            return false
        }

        /// What the row shows: its result's id, or its header's title.
        var key: String {
            switch self {
            case .header(let title): "header:" + title
            case .item(let row): row.id
            }
        }
    }

    /// Cells the table asked the data source for (`tableView(_:viewFor:row:)`): a row it made or took again.
    /// An update in place asks for none for the rows it keeps.
    private(set) var cellsAsked = 0

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
    /// The header and result row heights the table holds (``rowHeights``): rows kept in place keep theirs, so
    /// results set under other heights (a settings change no text size or window size follows) reload.
    private var heldHeights: [CGFloat] = []
    private var selectedID: String?
    private var hoveredID: String?
    /// No rubber band while every result fits.
    private var scrollFit: ScrollFitElasticity?

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        // The sidebar's thin knob on no track: the stock scroller drew a gray track on a Mac set to
        // show legacy scroll bars and took its width from every row (Lawrence 2026-11-15).
        SystemScrollers.followThin(self)
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
        let shown = self.rows, heights = rowHeights
        self.rows = rows
        rowIndexByID = index
        if heights != heldHeights || !updateInPlace(from: shown) { table.reloadData() }
        heldHeights = heights
        syncTableSelection()
        // Size the table now, not at the next display, so the rubber band
        // matches the new results before the next scroll event.
        table.tile()
    }

    /// Shows `rows` in the rows the table has, when they keep the shape of `shown` (a header where a header was, a
    /// result where a result was, so every height stays): each row view and cell the table holds is configured again
    /// with its new row, as a reused one is, and rows past the old end are inserted or removed. False when the shape
    /// changed (the caller reloads). A reload took every row out of the table and made each one again, with its first
    /// layout: every palette open (its first frame, then the full list after it) paid that for rows it already showed.
    private func updateInPlace(from shown: [DisplayRow]) -> Bool {
        let kept = min(shown.count, rows.count)
        guard kept > 0, table.numberOfRows == shown.count,
              (0..<kept).allSatisfy({ shown[$0].isHeader == rows[$0].isHeader }) else { return false }
        if rows.count > shown.count {
            table.insertRows(at: IndexSet(integersIn: shown.count..<rows.count), withAnimation: [])
        } else if rows.count < shown.count {
            table.removeRows(at: IndexSet(integersIn: rows.count..<shown.count), withAnimation: [])
        }
        var stale = IndexSet()
        table.enumerateAvailableRowViews { rowView, row in
            // Rows past the kept ones were just inserted (made for their rows); -1 is a row view leaving.
            guard (0..<kept).contains(row) else { return }
            if let rowView = rowView as? PaletteTableRowView {
                // Another row in this place: a hover fade asked for the old one is dropped, as on reuse.
                if shown[row].key != rows[row].key { rowView.dropPendingFade() }
                style(rowView, row: row)
            }
            if !fill(table.view(atColumn: 0, row: row, makeIfNecessary: false), row: row) { stale.insert(row) }
        }
        // A cell of another kind than its row's (none expected while the shape holds) is asked for again.
        if !stale.isEmpty { table.reloadData(forRowIndexes: stale, columnIndexes: IndexSet(integer: 0)) }
        return true
    }

    /// The row view's state for row `row` (selected, hovered), as the table's delegate gives a new one.
    private func style(_ view: PaletteTableRowView, row: Int) {
        if case .item(let item) = rows[row] {
            view.isPaletteSelected = item.id == selectedID
            view.isHovered = item.id == hoveredID
        } else {
            view.isPaletteSelected = false
            view.isHovered = false
        }
    }

    /// Configures `cell` for row `row`; false when it is not a cell of that row's kind.
    private func fill(_ cell: NSView?, row: Int) -> Bool {
        switch rows[row] {
        case .header(let title):
            guard let cell = cell as? PaletteSectionHeaderCell else { return false }
            cell.title = title
        case .item(let item):
            guard let cell = cell as? PaletteRowCell else { return false }
            cell.configure(item, isSelected: item.id == selectedID)
        }
        return true
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

    /// Configures every row again, in the current text size (#26606).
    func reloadRows() {
        table.reloadData()
        heldHeights = rowHeights
        syncTableSelection()
    }

    func relayoutRows() {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        heldHeights = rowHeights
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

    /// A header's height and a result row's (``tableView(_:heightOfRow:)``).
    private var rowHeights: [CGFloat] { [PaletteLayout.headerRowHeight, PaletteLayout.rowHeight] }

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
        style(view, row: row)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        cellsAsked += 1
        let cell: NSView = switch rows[row] {
        case .header:
            tableView.makeView(withIdentifier: PaletteSectionHeaderCell.identifier, owner: nil) as? PaletteSectionHeaderCell
                ?? PaletteSectionHeaderCell()
        case .item:
            tableView.makeView(withIdentifier: PaletteRowCell.identifier, owner: nil) as? PaletteRowCell
                ?? PaletteRowCell(frame: .zero)
        }
        _ = fill(cell, row: row)
        return cell
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
        set {
            label.refreshFont()
            label.stringValue = newValue
        }
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

/// The v2 rail (`PaletteV2Look.rail`), left of the list in the list's band: All, then each group the query's rows
/// have, its row count at the right (a mega menu's categories); the chosen one is a filled rounded pill like the
/// selected row. A click or ⌥↑ / ⌥↓ (``step(for:)``) narrows the list to that group. Rows are reused and only
/// restyled when the entries or the choice change; nothing animates.
final class PaletteRailView: NSView {
    var onChoose: ((PaletteV2Group?) -> Void)?
    private var entries: [PaletteV2RailEntry] = []
    private var chosen: PaletteV2Group?
    private var rowViews: [PaletteRailRowView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    required init?(coder: NSCoder) { nil }

    /// The rail step a key-down asks for: ⌥↑ the entry above, ⌥↓ the one below. Nil for any other key (the
    /// palette binds no ⌥-arrow; plain Left and Right move the caret or walk a tree page).
    static func step(for event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .option else { return nil }
        switch event.keyCode {
        case 126: return -1
        case 125: return 1
        default: return nil
        }
    }

    func update(entries: [PaletteV2RailEntry], chosen: PaletteV2Group?) {
        guard entries != self.entries || chosen != self.chosen else { return }
        self.entries = entries
        self.chosen = chosen
        while rowViews.count < entries.count {
            let row = PaletteRailRowView(frame: .zero)
            addSubview(row)
            rowViews.append(row)
        }
        for (index, row) in rowViews.enumerated() {
            guard entries.indices.contains(index) else {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            row.configure(entries[index], isChosen: entries[index].group == chosen)
            row.onClick = { [weak self] in self?.choose(at: index) }
        }
        needsLayout = true
    }

    private func choose(at index: Int) {
        guard entries.indices.contains(index) else { return }
        onChoose?(entries[index].group)
    }

    override func layout() {
        super.layout()
        // The list's own inset above the first row and at the rows' sides; the list column's rows keep theirs.
        let inset = PaletteLayout.listInset
        let height = PaletteLayout.rowHeight
        var y = inset
        for row in rowViews where !row.isHidden {
            row.frame = NSRect(x: inset, y: y, width: max(0, bounds.width - inset), height: height)
            y += height
        }
    }
}

/// One rail entry: its title on the left, its count right-aligned, the chosen one on the selection fill.
final class PaletteRailRowView: NSView {
    var onClick: (() -> Void)?
    private let title = PaletteText.label(Typography.body)
    private let count = PaletteText.label(Typography.caption, tone: .secondary)
    private var isChosen = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        count.alignment = .right
        addSubview(title)
        addSubview(count)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ entry: PaletteV2RailEntry, isChosen: Bool) {
        let text = entry.count.formatted()
        if title.stringValue != entry.title || count.stringValue != text {
            title.stringValue = entry.title
            count.stringValue = text
            needsLayout = true
        }
        if self.isChosen != isChosen {
            self.isChosen = isChosen
            needsDisplay = true
        }
        setAccessibilityLabel(entry.title)
        setAccessibilityValue(text)
        setAccessibilitySelected(isChosen)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isChosen else { return }
        performWithTheme {
            Palette.selectionFill.setFill()
            let radius = PaletteLayout.rowCornerRadius
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }

    override func layout() {
        super.layout()
        let side = Metrics.space4
        let countWidth = PaletteText.fittingWidth(count)
        let countHeight = PaletteText.height(count)
        count.frame = pixelAligned(NSRect(x: bounds.width - side - countWidth, y: (bounds.height - countHeight) / 2,
                                          width: countWidth, height: countHeight))
        let titleHeight = PaletteText.height(title)
        title.frame = pixelAligned(NSRect(x: side, y: (bounds.height - titleHeight) / 2,
                                          width: max(0, count.frame.minX - side - Metrics.space2), height: titleHeight))
    }
}
