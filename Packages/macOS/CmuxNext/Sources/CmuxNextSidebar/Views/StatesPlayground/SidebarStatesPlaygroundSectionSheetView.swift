import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one ``SidebarStatesPlaygroundSection`` in one appearance.
/// Its title ("Home filter · Dark"), then a grid: one column per density and text size
/// (``SidebarStatesPlaygroundColumn/all``), one row per look, each cell the look's real views as drawn, with its size
/// in points under it.
final class SidebarStatesPlaygroundSectionSheetView: NSView {
    let appearanceKind: SidebarStatesPlaygroundAppearance
    let columns: [SidebarStatesPlaygroundColumn]
    /// The rows' names, top to bottom.
    let lookTitles: [String]
    /// The cells, by column, then look (in ``lookTitles`` order).
    let cells: [SidebarStatesPlaygroundColumn: [SidebarStatesPlaygroundLookCell]]

    private static var margin: CGFloat { Metrics.space6 }
    private static var labelWidth: CGFloat { 180 }
    private static var columnGap: CGFloat { Metrics.space6 }
    private static var rowGap: CGFloat { Metrics.space3 }

    init(appearance: SidebarStatesPlaygroundAppearance, title: String, lookTitles: [String],
         columns: [SidebarStatesPlaygroundColumn], cells: [SidebarStatesPlaygroundColumn: [SidebarStatesPlaygroundLookCell]]) {
        appearanceKind = appearance
        self.columns = columns
        self.lookTitles = lookTitles
        self.cells = cells
        super.init(frame: .zero)
        self.appearance = appearance.appearance
        wantsLayer = true
        build(title: Strings.statesPlaygroundSection(title, appearance.title))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = appearanceKind == .dark ? NSColor(white: 0.1, alpha: 1).cgColor : NSColor(white: 0.94, alpha: 1).cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    private func label(_ text: String, font: NSFont, color: NSColor, at origin: NSPoint, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        let height = ceil(field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        field.frame = NSRect(x: origin.x, y: origin.y, width: width, height: height)
        addSubview(field)
        return field
    }

    /// Places the title, the column captions and every cell; the sheet's frame is the grid's size.
    private func build(title: String) {
        let margin = Self.margin
        let columnWidth = max(160, cells.values.flatMap { $0 }.map(\.size.width).max() ?? 0)
        let gridWidth = Self.labelWidth + CGFloat(columns.count) * (columnWidth + Self.columnGap)
        var y = margin
        let heading = label(title, font: Typography.title, color: .labelColor, at: NSPoint(x: margin, y: y), width: gridWidth)
        y = heading.frame.maxY + Metrics.space5
        func columnX(_ index: Int) -> CGFloat { margin + Self.labelWidth + CGFloat(index) * (columnWidth + Self.columnGap) }
        var captionBottom = y
        for (index, column) in columns.enumerated() {
            let caption = label(column.title, font: Typography.header, color: .labelColor, at: NSPoint(x: columnX(index), y: y), width: columnWidth)
            captionBottom = max(captionBottom, caption.frame.maxY)
        }
        y = captionBottom + Metrics.space3
        for (row, name) in lookTitles.enumerated() {
            var rowHeight: CGFloat = 0
            for (index, column) in columns.enumerated() {
                guard let looks = cells[column], looks.indices.contains(row) else { continue }
                let cell = looks[row]
                let x = columnX(index)
                var bottom = y
                if let image = cell.image {
                    let view = NSImageView(frame: NSRect(x: x, y: y, width: cell.size.width, height: cell.size.height))
                    view.image = NSImage(cgImage: image, size: cell.size)
                    view.imageScaling = .scaleAxesIndependently
                    addSubview(view)
                    bottom = view.frame.maxY
                }
                let size = cell.image == nil ? Strings.statesPlaygroundNotDrawn : SidebarStatesPlaygroundMark.text(cell.size)
                let caption = label(size, font: Typography.caption, color: .secondaryLabelColor,
                                    at: NSPoint(x: x, y: bottom + Metrics.space1), width: columnWidth)
                rowHeight = max(rowHeight, caption.frame.maxY - y)
            }
            let title = label(name, font: Typography.body, color: .labelColor, at: NSPoint(x: margin, y: y), width: Self.labelWidth - Metrics.space4)
            y += max(rowHeight, title.frame.height) + Self.rowGap
        }
        setFrameSize(NSSize(width: margin + gridWidth + margin - Self.columnGap, height: y - Self.rowGap + margin))
    }
}
