import AppKit

/// The columns layout (`NativePopupModel.columns`), as the web model picker's columns draw it
/// (quickModelColumns.css): the search row with its accessory (the account avatar) at the leading
/// edge, the rows that span the popup (a readiness note), then the columns side by side, each in
/// its own scroll view, then the footer. The page decides every column, row and check; this only
/// lays them out and moves the keyboard's highlight among them.
extension NativePopupContent {
    /// The search row's height: a 28 pt field with a 4 pt band above and below.
    static let columnsSearchRow: CGFloat = 36
    /// The band's cap when the page names none, as the web frame's (259 px less its search row).
    static let columnsDefaultHeight: CGFloat = 220

    func addColumns(_ model: NativePopupModel) {
        var views: [(NativePopupRow, NSView)] = []
        if let accessory = model.searchAccessory {
            let tab = NativePopupRailTab(row: accessory, placement: .symbols)
            tab.showsAccentBar = false
            tab.onActivate = { [weak self, weak tab] in
                guard let self, let tab else { return }
                activate(accessory, view: tab)
            }
            searchAccessoryTab = tab
            addSubview(tab)
            views.append((accessory, tab))
        }
        for row in model.rows {
            let view = makeRow(row, hasIconColumn: model.rows.contains { $0.icon != nil })
            addSubview(view)
            views.append((row, view))
        }
        for column in model.columns ?? [] {
            let view = NativePopupColumnView(column: column)
            let hasIcons = column.rows.contains { $0.icon != nil }
            for row in column.rows {
                let cell: NSView
                if column.rail == true {
                    let tab = NativePopupRailTab(row: row, placement: .symbols)
                    tab.showsAccentBar = false
                    tab.onActivate = { [weak self, weak tab] in
                        guard let self, let tab else { return }
                        activate(row, view: tab)
                    }
                    cell = tab
                } else {
                    cell = makeRow(row, hasIconColumn: hasIcons)
                }
                view.document.addSubview(cell)
                views.append((row, cell))
            }
            columnViews.append(view)
            addSubview(view)
        }
        for row in model.footer ?? [] {
            let view = makeRow(row, hasIconColumn: false)
            addSubview(view)
            views.append((row, view))
        }
        rowViews = views
    }

    /// Lays the columns layout out; returns the content height.
    func layoutColumns(title: NSView?, search: NSView?) -> CGFloat {
        guard let model else { return 0 }
        let width = bounds.width
        let inset = PopupStyle.standard.padding
        let hairline = Metrics.lineWidth(0.5)
        let columns = model.columns ?? []
        let byID = Dictionary(rowViews.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
        var lines: [NSRect] = []
        var y: CGFloat = 0
        if let title {
            title.frame = NSRect(x: inset + 7, y: inset, width: max(0, width - inset * 2 - 14), height: 24)
            y = inset + 24
        }
        // The search row: the accessory over the first column, its divider running up through it.
        let row = Self.columnsSearchRow
        let lead = model.searchAccessory == nil ? inset : CGFloat(columns.first?.width ?? 48)
        if let tab = searchAccessoryTab {
            let side = PopupStyle.standard.rowHeight
            tab.frame = NSRect(x: (lead - side) / 2, y: y + (row - side) / 2, width: side, height: side)
            lines.append(NSRect(x: lead - hairline, y: y, width: hairline, height: row))
        }
        search?.frame = NSRect(x: lead + 4, y: y + (row - 28) / 2, width: max(0, width - lead - inset - 8), height: 28)
        y += row
        lines.append(NSRect(x: 0, y: y, width: width, height: hairline))
        y += hairline
        // The rows that span the popup (the chat's readiness), then a hairline.
        if !model.rows.isEmpty {
            for spanning in model.rows {
                guard let view = byID[spanning.id] else { continue }
                let height = Self.height(of: spanning, view: view)
                view.frame = NSRect(x: inset, y: y, width: max(0, width - inset * 2), height: height)
                y += height
            }
            lines.append(NSRect(x: 0, y: y, width: width, height: hairline))
            y += hairline
        }
        // The columns: as tall as the tallest, up to the cap, and never shorter than they have been.
        let fixed = columns.compactMap(\.width).reduce(0, +)
        let flexible = columns.filter { $0.width == nil }.count
        let rest = flexible > 0 ? max(0, (width - CGFloat(fixed)) / CGFloat(flexible)) : 0
        var heights: [CGFloat] = []
        for column in columns {
            var cursor = inset
            let columnWidth = column.width.map { CGFloat($0) } ?? rest
            for item in column.rows {
                guard let cell = byID[item.id] else { continue }
                if let tab = cell as? NativePopupRailTab {
                    let side = PopupStyle.standard.rowHeight
                    tab.frame = NSRect(x: (columnWidth - side) / 2, y: cursor, width: side, height: side)
                    cursor += side + Metrics.space1
                } else {
                    let height = Self.height(of: item, view: cell)
                    cell.frame = NSRect(x: inset, y: cursor, width: max(0, columnWidth - inset * 2), height: height)
                    cursor += height
                }
            }
            heights.append(cursor + inset)
        }
        let cap = CGFloat(model.columnsHeight ?? Double(Self.columnsDefaultHeight))
        let band = min(cap, max(columnsBandFloor, heights.max() ?? 0))
        columnsBandFloor = band
        var x: CGFloat = 0
        for (index, (column, view)) in zip(columns, columnViews).enumerated() {
            let columnWidth = column.width.map { CGFloat($0) } ?? rest
            view.frame = NSRect(x: x, y: y, width: columnWidth, height: band)
            view.document.frame = NSRect(x: 0, y: 0, width: columnWidth, height: max(band, heights[index]))
            x += columnWidth
            if index < columns.count - 1 { lines.append(NSRect(x: x - hairline, y: y, width: hairline, height: band)) }
        }
        y += band
        // The footer under a hairline.
        if let footer = model.footer, !footer.isEmpty {
            lines.append(NSRect(x: 0, y: y, width: width, height: hairline))
            y += hairline
            for item in footer {
                guard let view = byID[item.id] else { continue }
                let height = Self.height(of: item, view: view)
                view.frame = NSRect(x: inset, y: y, width: max(0, width - inset * 2), height: height)
                y += height
            }
            y += inset
        }
        placeLines(lines)
        return y
    }

    /// One hairline view per rect, reused across layouts.
    private func placeLines(_ rects: [NSRect]) {
        while columnsLines.count < rects.count {
            let line = NSBox.separator()
            addSubview(line)
            columnsLines.append(line)
        }
        for (line, rect) in zip(columnsLines, rects) { line.frame = rect; line.isHidden = false }
        for line in columnsLines.dropFirst(rects.count) { line.isHidden = true }
    }

    private static func height(of row: NativePopupRow, view: NSView) -> CGFloat {
        (view as? NativePopupSliderView)?.preferredHeight
            ?? (row.kind == .separator ? 9 : row.kind == .textField ? 32 : row.description?.isEmpty == false ? 44 : PopupStyle.standard.rowHeight)
    }

    // MARK: Keys

    /// The column each row sits in, by the row's id.
    private func columnIndex(of id: String?) -> Int? {
        guard let id else { return nil }
        return model?.columns?.firstIndex { $0.rows.contains { $0.id == id } }
    }

    private func columnRows(_ index: Int) -> [(NativePopupRow, NSView)] {
        guard let column = model?.columns?[safe: index] else { return [] }
        let ids = Set(column.rows.map(\.id))
        return enabledRows.filter { ids.contains($0.0.id) }
    }

    var firstListColumnRowID: String? {
        guard let columns = model?.columns else { return nil }
        let start = columns.firstIndex { $0.rail != true } ?? 0
        return columnRows(start).first?.0.id
    }

    /// Up and Down stay in the highlighted row's column and stop at its ends; Left and Right move
    /// to the next column's checked row (else its first). Other keys fall through (nil).
    func handleColumnKey(_ key: UInt16) -> Bool? {
        guard let columns = model?.columns, [123, 124, 125, 126].contains(key) else { return nil }
        let home = columns.firstIndex { $0.rail != true } ?? 0
        let current = columnIndex(of: selected) ?? home
        let next: String?
        if key == 123 || key == 124 {
            // The nearest column that way with a row the keys can reach.
            let toward = key == 124 ? Array(columns.indices.filter { $0 > current })
                : Array(columns.indices.filter { $0 < current }.reversed())
            guard let target = toward.first(where: { !columnRows($0).isEmpty }) else { return true }
            let rows = columnRows(target)
            next = (rows.first { $0.0.checked == true } ?? rows.first)?.0.id
        } else {
            let rows = columnRows(current)
            guard !rows.isEmpty else { return true }
            let at = rows.firstIndex { $0.0.id == selected }
            let index = at.map { min(rows.count - 1, max(0, $0 + (key == 125 ? 1 : -1))) } ?? (key == 125 ? 0 : rows.count - 1)
            next = rows[index].0.id
        }
        guard let next, next != selected else { return true }
        selected = next
        selectionReason = "keyboard"
        paintSelection()
        emit(.highlight, next, nil)
        return true
    }
}

/// One column: a vertical scroll view with a flipped document that holds its rows.
@MainActor
final class NativePopupColumnView: NSScrollView {
    let column: NativePopupColumn
    let document = NativePopupRailStripDocument()

    init(column: NativePopupColumn) {
        self.column = column
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = column.rail != true
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = document
        setAccessibilityLabel(column.label)
        setAccessibilityIdentifier(column.id)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
