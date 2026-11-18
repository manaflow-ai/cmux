import AppKit
import CmuxVisibleRows

/// A row view alive in the popup, and the row it was built from (an equal incoming row keeps it).
struct NativePopupMountedRow {
    let row: NativePopupRow
    let view: NSView
    let hasIconColumn: Bool
    /// A rail column's tab, not a row.
    var tab = false
}

/// A run of rows' geometry, known before any row view exists. Each part (a rail column, the rows,
/// the footer) is a run of rows from its own top (``RowOffsets``, CmuxVisibleRows), so the rows
/// in a band are a binary search per part.
struct NativePopupWindowLayout {
    struct Part {
        var start: Int
        var offsets: RowOffsets
        /// The part's top and leading edge in its document (a placed rail's are set by its layout).
        var y: CGFloat = 0
        var x: CGFloat = 0
        /// A fixed width (the plain list's rail column); 0: to the document's trailing inset.
        var width: CGFloat = 0
        var range: Range<Int> { start..<(start + offsets.count) }
    }

    var parts: [Part] = []
    var hasIconColumn = false
    /// Each row a centered square tab of the row height, a gap after it (a rail column).
    var tabs = false
    /// The plain list's height, insets included.
    var height: CGFloat = 0

    /// A row's height before its view exists. `footer`: the plain list's footer, whose text
    /// fields keep the row height.
    static func height(of row: NativePopupRow, footer: Bool = false) -> CGFloat {
        if row.kind == .slider, let descriptor = row.slider { return NativePopupSliderView.preferredHeight(for: descriptor) }
        return row.kind == .separator ? 9 : !footer && row.kind == .textField ? 32
            : row.description?.isEmpty == false ? 44 : PopupStyle.standard.rowHeight
    }

    /// Appends `rows` as a part; returns its length.
    @discardableResult
    mutating func append(_ rows: [NativePopupRow], y: CGFloat = 0, x: CGFloat = 0, width: CGFloat = 0,
                         height: (NativePopupRow) -> CGFloat) -> CGFloat {
        let offsets = RowOffsets(heights: rows.map { Double(height($0)) })
        parts.append(Part(start: parts.last?.range.upperBound ?? 0, offsets: offsets, y: y, x: x, width: width))
        return CGFloat(offsets.length)
    }

    /// The length of part `index`.
    func length(of index: Int) -> CGFloat {
        parts.indices.contains(index) ? CGFloat(parts[index].offsets.length) : 0
    }

    /// The plain list: the rail column, the rows under the title and search, then the footer.
    static func plain(_ model: NativePopupModel) -> Self {
        var layout = Self()
        let inset = PopupStyle.standard.padding
        let rail = model.rail ?? []
        let railWidth: CGFloat = rail.isEmpty ? 0 : CGFloat(model.railWidth ?? 48)
        layout.hasIconColumn = (rail + model.rows + (model.footer ?? [])).contains { $0.icon != nil }
        let railLength = layout.append(rail, y: inset, x: inset, width: railWidth) { row in
            row.kind == .slider ? height(of: row) : 40
        }
        var y = inset
        if model.title?.isEmpty == false { y += 24 }
        if model.search != nil { y += 34 }
        y += layout.append(model.rows, y: y, x: inset + railWidth) { height(of: $0) }
        y = max(y, inset + railLength)
        y += layout.append(model.footer ?? [], y: y, x: inset + railWidth) { height(of: $0, footer: true) }
        layout.height = y + inset
        return layout
    }

    /// A placed rail's list: the rows, then the footer; ``NativePopupContent/layoutPlacedRail``
    /// places both parts under the rail.
    static func placed(_ model: NativePopupModel) -> Self {
        var layout = Self()
        let rows = model.rows + (model.footer ?? [])
        layout.hasIconColumn = rows.contains { $0.icon != nil }
        layout.append(model.rows) { height(of: $0) }
        layout.append(model.footer ?? [], x: PopupStyle.standard.padding) { height(of: $0) }
        return layout
    }

    /// One column's rows, or its tabs (a rail column).
    static func column(_ column: NativePopupColumn) -> Self {
        var layout = Self()
        let inset = PopupStyle.standard.padding
        layout.tabs = column.rail == true
        layout.hasIconColumn = !layout.tabs && column.rows.contains { $0.icon != nil }
        let tabs = layout.tabs
        layout.append(column.rows, y: inset, x: inset) { row in
            tabs ? PopupStyle.standard.rowHeight + Metrics.space1 : height(of: row)
        }
        return layout
    }

    /// The row at `index` in a document `width` wide.
    func frame(_ index: Int, width: CGFloat) -> NSRect {
        guard let part = parts.first(where: { $0.range.contains(index) }) else { return .zero }
        let y = part.y + CGFloat(part.offsets.tops[index - part.start])
        if tabs {
            let side = PopupStyle.standard.rowHeight
            return NSRect(x: (width - side) / 2, y: y, width: side, height: side)
        }
        let rowWidth = part.width > 0 ? part.width : max(0, width - part.x - PopupStyle.standard.padding)
        return NSRect(x: part.x, y: y, width: rowWidth, height: CGFloat(part.offsets.heights[index - part.start]))
    }

    /// The rows that meet `band`, in display order.
    func indices(in band: NSRect) -> [Int] {
        parts.flatMap { part in
            let local = RowBand(minY: Double(band.minY), maxY: Double(band.maxY)).relative(to: Double(part.y))
            return part.offsets.rows(from: local.minY, to: local.maxY).map { $0 + part.start }
        }
    }
}

/// One run of rows drawn by band in one scrolling document: the popup's own list (the plain list,
/// a placed rail's list) or one column.
@MainActor
final class NativePopupRowWindow {
    weak var document: NSView?
    var layout: NativePopupWindowLayout
    var rows: [NativePopupRow]
    let index: [String: Int]

    init(document: NSView, layout: NativePopupWindowLayout, rows: [NativePopupRow]) {
        self.document = document
        self.layout = layout
        self.rows = rows
        index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The band rows are drawn in: the document's viewport and one viewport each side; the whole
    /// document when nothing scrolls it.
    var band: NSRect {
        guard let document else { return .zero }
        guard let scroll = document.enclosingScrollView, scroll.documentView === document else { return document.bounds }
        let visible = scroll.documentVisibleRect
        let band = RowBand(viewportTop: Double(visible.minY), height: Double(visible.height))
        return NSRect(x: visible.minX, y: CGFloat(band.minY), width: visible.width, height: CGFloat(band.maxY - band.minY))
    }

    func frame(_ index: Int) -> NSRect { layout.frame(index, width: document?.bounds.width ?? 0) }
}

/// Every list in the popup draws only the rows in and around its viewport (one viewport above and
/// below), keeps an equal row's view across updates, and moves the highlight on the two rows
/// involved. A few rows outside any list (a column layout's spanning rows and footer, its search
/// accessory, a placed rail's tabs) are always drawn.
extension NativePopupContent {
    /// Indexes the shown rows after a rebuild: their places, the rows the keys move among, the
    /// rail tabs Return reaches, the digit keys, and each column's rows.
    func indexRows(_ model: NativePopupModel) {
        shownIndex = Dictionary(shownRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rail = Set((model.rail ?? []).map(\.id))
        var excluded = rail
        if let accessory = model.searchAccessory { excluded.insert(accessory.id) }
        listRows = shownRows.filter { !$0.isNoninteractive && $0.disabled != true && !excluded.contains($0.id) }
        listIndex = Dictionary(listRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        railRowIDs = Set(shownRows.filter { $0.disabled != true && rail.contains($0.id) }.map(\.id))
        shortcutRows = [:]
        for row in listRows { if let key = row.shortcut, shortcutRows[key] == nil { shortcutRows[key] = row.id } }
        columnOf = [:]
        for (index, column) in (model.columns ?? []).enumerated() { for row in column.rows { columnOf[row.id] = index } }
        columnListRows = (model.columns ?? []).map { $0.rows.filter { listIndex[$0.id] != nil } }
        columnListPosition = [:]
        for rows in columnListRows { for (position, row) in rows.enumerated() { columnListPosition[row.id] = position } }
        listWork.walked(shownRows.count)
    }

    /// Draws `rows` by band in `document`, with `layout`'s geometry.
    func addWindow(_ document: NSView, layout: NativePopupWindowLayout, rows: [NativePopupRow]) {
        let window = NativePopupRowWindow(document: document, layout: layout, rows: rows)
        for row in rows { windowOf[row.id] = rowWindows.count }
        rowWindows.append(window)
    }

    /// The row `id` names when a click or Return reaches it: a list row or a rail tab.
    func selectableRow(_ id: String?) -> NativePopupRow? {
        guard let id, listIndex[id] != nil || railRowIDs.contains(id), let index = shownIndex[id] else { return nil }
        return shownRows[index]
    }

    /// The list row `id` names (Up, Down, digits and typeahead reach it).
    func listRow(_ id: String?) -> NativePopupRow? { id.flatMap { listIndex[$0] }.map { listRows[$0] } }

    /// Mounts each list's rows in its band, drops the rows that left it (never the one with the
    /// keys or a slider AppKit is tracking), and keeps the views of rows that did not change.
    func realizeVisibleRows() {
        guard !rowWindows.isEmpty, !isRealizing else { return }
        isRealizing = true
        defer { isRealizing = false }
        for (number, window) in rowWindows.enumerated() {
            var wanted = Set(window.layout.indices(in: window.band).map { window.rows[$0].id })
            for (id, mount) in mounted where windowOf[id] == number && !wanted.contains(id) && isPinned(mount) { wanted.insert(id) }
            for (id, mount) in reusable where windowOf[id] == number && !wanted.contains(id) && isPinned(mount) { wanted.insert(id) }
            for (id, mount) in mounted where windowOf[id] == number && !wanted.contains(id) { forget(mount); mounted[id] = nil }
            for index in wanted.compactMap({ window.index[$0] }).sorted() where mounted[window.rows[index].id] == nil {
                mount(window.rows[index].id)
            }
            orderRows(number)
        }
        for mount in reusable.values { forget(mount) }
        reusable = [:]
    }

    /// Lays out the mounted rows; a row whose frame did not change is not touched.
    func placeMountedRows() {
        for (id, mount) in mounted {
            guard let number = windowOf[id], let index = rowWindows[number].index[id] else { continue }
            place(mount.view, rowWindows[number].frame(index))
        }
    }

    /// The view of list row `id`, made (or taken back from the last rebuild) if it has none.
    @discardableResult
    func mount(_ id: String) -> NSView? {
        if let view = mounted[id]?.view { return view }
        guard let number = windowOf[id], let index = rowWindows[number].index[id],
              let document = rowWindows[number].document else { return nil }
        let window = rowWindows[number]
        let row = window.rows[index]
        let hasIcons = window.layout.hasIconColumn
        let entry: NativePopupMountedRow
        let old = reusable.removeValue(forKey: id)
        if let old, old.row == row, old.hasIconColumn == hasIcons, old.tab == window.layout.tabs {
            entry = old
            if old.view.superview !== document { document.addSubview(old.view) }
        } else {
            if let old { forget(old) }
            let start = targets.count
            let view = window.layout.tabs ? makeColumnTab(row) : makeRow(row, hasIconColumn: hasIcons)
            rowTargets[id] = Array(targets[start...])
            targets.removeSubrange(start...)
            highlight(view, id == selected)
            document.addSubview(view)
            entry = NativePopupMountedRow(row: row, view: view, hasIconColumn: hasIcons, tab: window.layout.tabs)
        }
        mounted[id] = entry
        place(entry.view, window.frame(index))
        return entry.view
    }

    /// A rail column's tab (the model picker's harnesses).
    func makeColumnTab(_ row: NativePopupRow) -> NSView {
        listWork.configured()
        let tab = NativePopupRailTab(row: row, placement: .symbols)
        tab.showsAccentBar = false
        tab.onActivate = { [weak self, weak tab] in
            guard let self, let tab else { return }
            activate(row, view: tab)
        }
        return tab
    }

    /// Drops a row's view and what it registered (its fields, controls and their targets).
    func forget(_ mount: NativePopupMountedRow) {
        mount.view.removeFromSuperview()
        for key in Self.keys(of: mount.row) {
            if fields[key]?.isDescendant(of: mount.view) == true { fields[key] = nil }
            if editableControls[key]?.isDescendant(of: mount.view) == true { editableControls[key] = nil }
        }
        rowTargets[mount.row.id] = nil
    }

    /// The ids a row's controls register under: the row's, then its accessory actions'.
    static func keys(of row: NativePopupRow) -> [String] { [row.id] + (row.actions ?? []).map(\.id) }

    /// A row that must stay mounted: it holds the keys, or AppKit tracks its slider.
    func isPinned(_ mount: NativePopupMountedRow) -> Bool {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: mount.view) { return true }
        if fields[mount.row.id]?.currentEditor() != nil { return true }
        if let view = mount.view as? NativePopupSliderView, view.slider.isInteracting { return true }
        return (editableControls[mount.row.id] as? NativePopupTrackingSlider)?.isInteracting == true
    }

    func place(_ view: NSView, _ frame: NSRect) {
        guard view.frame != frame else { return }
        view.frame = frame
        listWork.laidOut()
    }

    /// Sets a row's highlight; true when it changed.
    @discardableResult
    func highlight(_ view: NSView?, _ on: Bool) -> Bool {
        if let row = view as? PopupRowView, row.isHighlighted != on { row.isHighlighted = on; return true }
        if let tab = view as? NativePopupRailTab, tab.isHighlighted != on { tab.isHighlighted = on; return true }
        return false
    }

    /// Keeps a list's document in reading order for accessibility: what is not a list row where it
    /// is (the title, the search field, a rail), then the list's rows top to bottom. Reorders only
    /// when a mount or a rebuild changed it.
    func orderRows(_ number: Int) {
        guard rowWindows.indices.contains(number), let document = rowWindows[number].document else { return }
        let window = rowWindows[number]
        let rows = mounted.compactMap { id, mount in windowOf[id] == number ? window.index[id].map { ($0, mount.view) } : nil }
            .sorted { $0.0 < $1.0 }.map(\.1)
        let listed = Set(rows.map(ObjectIdentifier.init))
        let desired = document.subviews.filter { !listed.contains(ObjectIdentifier($0)) } + rows
        if !zip(document.subviews, desired).allSatisfy({ $0 === $1 }) || document.subviews.count != desired.count {
            document.subviews = desired
        }
    }
}

/// A list that draws only the rows in view: its clip view tells it each time what it shows moves
/// or resizes.
@MainActor
protocol PopupViewportFollowing: AnyObject {
    func viewportDidChange()
}

/// The popups' clip view: a scroll (a wheel, a scroller drag, `scrollToVisible`) or a resize (the
/// popup sized to its rows) tells the document (``NativePopupContent``, ``WebPopupRows``), which
/// draws the rows that came into view and drops the rows that left.
final class PopupClipView: NSClipView {
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        (documentView as? PopupViewportFollowing)?.viewportDidChange()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        (documentView as? PopupViewportFollowing)?.viewportDidChange()
    }
}

extension NativePopupContent: PopupViewportFollowing, VisibleRowsList {
    var rowViewsAlive: Int { mounted.count }
    func viewportDidChange() { realizeVisibleRows() }
}
