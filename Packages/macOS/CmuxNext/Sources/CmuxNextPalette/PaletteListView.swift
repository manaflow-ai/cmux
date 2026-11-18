import AppKit
import CmuxNextDesign
import CmuxNextCompat
import CmuxVisibleRows

/// The result list: an `NSTableView` with reused row views. Only visible
/// rows exist. Results apply in place by id without animation (no flicker),
/// configuring only mounted rows whose content changed; selection and hover
/// update just the affected row views.
final class PaletteListView: OverlayScrollView, NSTableViewDataSource, NSTableViewDelegate {
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

    /// Internal for the render count tests.
    let table = PaletteTableView()
    /// The row a middle press went down on (`onMiddleClick`).
    private var middlePressID: String?
    private var rows: [DisplayRow] = []
    /// Each row's stable id (an item's id, a header's section id), by row.
    private var rowKeys: [String] = []
    private var rowIndexByID: [String: Int] = [:]
    /// The toggle style rows were configured in (a change configures every mounted row again).
    private var appliedToggleStyle = PaletteTunables.toggleStyle.value
    /// The row heights the table holds (`relayoutRows`).
    private var appliedRowHeights = PaletteListView.rowHeights
    /// Rows configured (`viewFor`), heights asked (`heightOfRow`) and results read (`setSections`): the
    /// visible-rows contract (`PaletteListVisibleRowsTests`).
    let listWork = ListWorkMeter()
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

    /// Applies new results by stable id: rows that left are removed, new or moved rows are
    /// inserted, and a kept row is configured again only when it is mounted and what it draws
    /// changed. A keystroke that keeps the visible rows configures none of them, and the table
    /// asks the heights of inserted rows only, at 100 results as at 10,000.
    func setSections(_ sections: [PaletteResultSection]) {
        var rows: [DisplayRow] = []
        var keys: [String] = []
        var index: [String: Int] = [:]
        for section in sections {
            if !section.title.isEmpty {
                rows.append(.header(section.title))
                keys.append(Self.headerKey(section.id))
            }
            for row in section.rows {
                index[row.id] = rows.count
                rows.append(.item(row))
                keys.append(row.id)
            }
        }
        // The model hands every result each version: reading them and indexing the old ones by id is
        // the one pass over N (no row is configured or measured for it).
        listWork.walked(rows.count + self.rows.count)
        let oldRows = self.rows
        let oldKeys = rowKeys
        self.rows = rows
        rowKeys = keys
        rowIndexByID = index
        let toggleStyle = PaletteTunables.toggleStyle.value
        if toggleStyle != appliedToggleStyle || !apply(from: oldKeys, oldRows: oldRows) {
            table.reloadData()
        }
        appliedToggleStyle = toggleStyle
        syncTableSelection()
        // Size the table now, not at the next display, so the rubber band
        // matches the new results before the next scroll event.
        table.tile()
    }

    /// Moves the table from `oldKeys` to `rowKeys` in place; false when a full reload is the
    /// same work (nothing kept) or the keys are not unique.
    private func apply(from oldKeys: [String], oldRows: [DisplayRow]) -> Bool {
        guard !oldKeys.isEmpty, !rowKeys.isEmpty else { return false }
        var oldIndexByKey: [String: Int] = [:]
        oldIndexByKey.reserveCapacity(oldKeys.count)
        for (i, key) in oldKeys.enumerated() {
            guard oldIndexByKey.updateValue(i, forKey: key) == nil else { return false }
        }
        // The kept rows in their new order, by old index: the longest increasing run of them stays
        // put, and every other kept row moves (a remove and an insert).
        var keptNew: [Int] = []
        var keptOld: [Int] = []
        var seen = Set<String>(minimumCapacity: rowKeys.count)
        for (i, key) in rowKeys.enumerated() {
            guard seen.insert(key).inserted else { return false }
            if let old = oldIndexByKey[key] {
                keptNew.append(i)
                keptOld.append(old)
            }
        }
        guard !keptOld.isEmpty else { return false }
        var removed = IndexSet(integersIn: 0..<oldKeys.count)
        var inserted = IndexSet(integersIn: 0..<rowKeys.count)
        for k in Self.longestIncreasingRun(keptOld) {
            removed.remove(keptOld[k])
            inserted.remove(keptNew[k])
        }
        if !removed.isEmpty || !inserted.isEmpty {
            // No animation: rows land in place, as a reload drew them.
            table.beginUpdates()
            // Removals name old rows; insertions name the rows' final places.
            if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
            if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
            table.endUpdates()
        }
        // A kept row that is mounted is configured again only if what it draws changed.
        var changed = IndexSet()
        table.enumerateAvailableRowViews { _, row in
            guard rows.indices.contains(row), !inserted.contains(row), let old = oldIndexByKey[rowKeys[row]] else { return }
            if !Self.drawsSame(oldRows[old], rows[row]) { changed.insert(row) }
        }
        if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        return true
    }

    /// Indexes into `values` of one longest strictly increasing subsequence.
    static func longestIncreasingRun(_ values: [Int]) -> [Int] {
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: values.count)
        for (i, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var run: [Int] = []
        var i = tails.last ?? -1
        while i >= 0 {
            run.append(i)
            i = previous[i]
        }
        return run.reversed()
    }

    private static func headerKey(_ sectionID: String) -> String { "\u{1}header:\(sectionID)" }

    /// Whether two rows draw the same (what `PaletteRowCell.configure` reads).
    private static func drawsSame(_ a: DisplayRow, _ b: DisplayRow) -> Bool {
        switch (a, b) {
        case (.header(let x), .header(let y)): x == y
        case (.item(let x), .item(let y)): RowLook(x) == RowLook(y)
        default: false
        }
    }

    /// What a result row draws.
    private struct RowLook: Equatable {
        var title: String, subtitle: String?, accessory: String?, symbol: String?, brand: String?
        var image: ObjectIdentifier?, keycaps: [String]?, swatches: [ThemeRGB], fontFamily: String?
        var ball: PaletteBall?, highlights: [Int], subtitleHighlights: [Int], toggleState: Bool?, isEnabled: Bool

        init(_ row: PaletteRow) {
            let item = row.item
            title = item.title
            subtitle = item.subtitle
            accessory = item.accessory
            symbol = item.symbol
            brand = item.brand
            image = item.image.map { ObjectIdentifier($0) }
            keycaps = item.keycaps
            swatches = item.swatches
            fontFamily = item.fontFamily
            ball = item.ball
            highlights = row.highlights
            subtitleHighlights = item.subtitleHighlights
            toggleState = item.toggleState
            isEnabled = item.isEnabled
        }
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
        appliedRowHeights = Self.rowHeights
        table.reloadData()
        syncTableSelection()
    }

    /// Tells the table the row heights changed, only when they did (a density or text size
    /// change); a window size change alone leaves every height as it was.
    func relayoutRows() {
        let heights = Self.rowHeights
        guard heights != appliedRowHeights else { return }
        appliedRowHeights = heights
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    private static var rowHeights: [CGFloat] { [PaletteLayout.rowHeight, PaletteLayout.headerRowHeight] }

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
        listWork.laidOut()
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
        listWork.configured()
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

extension PaletteListView: VisibleRowsList {
    /// The table's row views, shown and parked for reuse.
    var rowViewsAlive: Int { table.subviews.count { $0 is NSTableRowView } }
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
