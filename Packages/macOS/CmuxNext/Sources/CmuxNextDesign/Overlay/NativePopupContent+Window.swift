import AppKit
import CmuxVisibleRows

/// A row view alive in the popup, and the row it was built from (an equal incoming row keeps it).
struct NativePopupMountedRow {
    let row: NativePopupRow
    let view: NSView
    let hasIconColumn: Bool
}

/// The plain list's geometry (no columns, no placed rail), known before any row view exists:
/// each shown row's top and height. The rail column, the rows and the footer each run top to
/// bottom, so the rows in a band are a binary search per part.
struct NativePopupWindowLayout {
    var tops: [CGFloat] = []
    var heights: [CGFloat] = []
    var parts: [Range<Int>] = []
    var railCount = 0
    var railWidth: CGFloat = 0
    var hasIconColumn = false
    var height: CGFloat = 0

    init(_ model: NativePopupModel, rows: [NativePopupRow]) {
        let inset = PopupStyle.standard.padding
        let rail = model.rail ?? []
        railCount = rail.count
        railWidth = rail.isEmpty ? 0 : CGFloat(model.railWidth ?? 48)
        hasIconColumn = rows.contains { $0.icon != nil }
        func slider(_ row: NativePopupRow) -> CGFloat? {
            row.kind == .slider ? row.slider.map(NativePopupSliderView.preferredHeight(for:)) : nil
        }
        var railY = inset
        for row in rail {
            tops.append(railY); heights.append(slider(row) ?? 40); railY += heights[heights.count - 1]
        }
        var y = inset
        if model.title?.isEmpty == false { y += 24 }
        if model.search != nil { y += 34 }
        let body = model.rows
        for row in body {
            let height = slider(row) ?? (row.kind == .separator ? 9 : row.kind == .textField ? 32
                : row.description?.isEmpty == false ? 44 : PopupStyle.standard.rowHeight)
            tops.append(y); heights.append(height); y += height
        }
        y = max(y, railY)
        for row in model.footer ?? [] {
            let height = slider(row) ?? (row.kind == .separator ? 9 : row.description?.isEmpty == false ? 44 : PopupStyle.standard.rowHeight)
            tops.append(y); heights.append(height); y += height
        }
        height = y + inset
        parts = [0..<railCount, railCount..<(railCount + body.count), (railCount + body.count)..<tops.count]
    }

    /// The row at `index` in a list `width` wide.
    func frame(_ index: Int, width: CGFloat) -> NSRect {
        let inset = PopupStyle.standard.padding
        if index < railCount { return NSRect(x: inset, y: tops[index], width: railWidth, height: heights[index]) }
        let x = inset + railWidth
        return NSRect(x: x, y: tops[index], width: max(0, width - x - inset), height: heights[index])
    }

    /// The rows that meet `band`, in display order.
    func indices(in band: NSRect) -> [Int] {
        var found: [Int] = []
        for part in parts where !part.isEmpty {
            var low = part.lowerBound, high = part.upperBound
            while low < high {
                let mid = (low + high) / 2
                if tops[mid] + heights[mid] <= band.minY { low = mid + 1 } else { high = mid }
            }
            while low < part.upperBound, tops[low] < band.maxY { found.append(low); low += 1 }
        }
        return found
    }
}

/// The plain list draws only the rows in and around its viewport (one viewport above and below),
/// keeps an equal row's view across updates, and moves the highlight on the two rows involved.
extension NativePopupContent {

    /// Indexes the shown rows after a rebuild: their places, the rows the keys move among, the
    /// rail tabs Return reaches, and the digit keys.
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
    }

    /// The row `id` names when a click or Return reaches it: a list row or a rail tab.
    func selectableRow(_ id: String?) -> NativePopupRow? {
        guard let id, listIndex[id] != nil || railRowIDs.contains(id), let index = shownIndex[id] else { return nil }
        return shownRows[index]
    }

    /// The list row `id` names (Up, Down, digits and typeahead reach it).
    func listRow(_ id: String?) -> NativePopupRow? { id.flatMap { listIndex[$0] }.map { listRows[$0] } }

    /// The band rows are drawn in: the viewport and one viewport each side; the whole list when
    /// nothing scrolls it.
    var windowBand: NSRect {
        guard let scroll = enclosingScrollView, scroll.documentView === self else { return bounds }
        let visible = scroll.documentVisibleRect
        return visible.insetBy(dx: 0, dy: -visible.height)
    }

    /// Mounts the rows in the band, drops the rows that left it (never the one with the keys or a
    /// slider AppKit is tracking), and keeps the views of rows that did not change.
    func realizeVisibleRows() {
        guard let layout = windowLayout, !isRealizing else { return }
        isRealizing = true
        defer { isRealizing = false }
        var wanted = Set(layout.indices(in: windowBand).map { shownRows[$0].id })
        for (id, mount) in mounted where !wanted.contains(id) && isPinned(mount) { wanted.insert(id) }
        for (id, mount) in reusable where !wanted.contains(id) && shownIndex[id] != nil && isPinned(mount) { wanted.insert(id) }
        for (id, mount) in mounted where !wanted.contains(id) { forget(mount); mounted[id] = nil }
        for index in wanted.compactMap({ shownIndex[$0] }).sorted() where mounted[shownRows[index].id] == nil { mount(index) }
        for mount in reusable.values { forget(mount) }
        reusable = [:]
        orderRows()
    }

    /// Lays out the mounted rows; a row whose frame did not change is not touched.
    func placeMountedRows() {
        guard let layout = windowLayout else { return }
        for (id, mount) in mounted { if let index = shownIndex[id] { place(mount.view, layout.frame(index, width: bounds.width)) } }
    }

    @discardableResult
    func mount(_ index: Int) -> NSView? {
        guard let layout = windowLayout, shownRows.indices.contains(index) else { return nil }
        let row = shownRows[index]
        if let view = mounted[row.id]?.view { return view }
        let entry: NativePopupMountedRow
        let old = reusable.removeValue(forKey: row.id)
        if let old, old.row == row, old.hasIconColumn == layout.hasIconColumn {
            entry = old
        } else {
            if let old { forget(old) }
            let start = targets.count
            let view = makeRow(row, hasIconColumn: layout.hasIconColumn)
            rowTargets[row.id] = Array(targets[start...])
            targets.removeSubrange(start...)
            highlight(view, row.id == selected)
            addSubview(view)
            entry = NativePopupMountedRow(row: row, view: view, hasIconColumn: layout.hasIconColumn)
        }
        mounted[row.id] = entry
        place(entry.view, layout.frame(index, width: bounds.width))
        return entry.view
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

    /// Keeps the subviews in reading order (title, search, rows top to bottom) for accessibility;
    /// reorders only when a mount or a rebuild changed it.
    func orderRows() {
        let rows = mounted.compactMap { id, mount in shownIndex[id].map { ($0, mount.view) } }.sorted { $0.0 < $1.0 }.map(\.1)
        let desired = [title, search].compactMap(\.self) + rows
        if subviews.count != desired.count || !zip(subviews, desired).allSatisfy({ $0 === $1 }) { subviews = desired }
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
