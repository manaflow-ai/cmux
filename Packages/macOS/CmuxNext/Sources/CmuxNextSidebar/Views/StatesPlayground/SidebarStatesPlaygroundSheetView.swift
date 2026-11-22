import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one appearance's sheet. A title and the legend, then a
/// grid: one column per density and text size (``SidebarStatesPlaygroundColumn/all``, or
/// ``SidebarStatesPlaygroundColumn/favicons(_:)`` drawn with one favicon style), one row per state of ``states``, each cell the real row
/// (``SidebarStatesPlaygroundCellView``).
///
/// ``labelFrame`` and ``densityFrames`` name the sheet's parts, so a capture can cut one density's columns out with
/// the state names beside them.
final class SidebarStatesPlaygroundSheetView: NSView {
    let appearanceKind: SidebarStatesPlaygroundAppearance
    let columns: [SidebarStatesPlaygroundColumn]
    /// The rows, in order: every state, or the favicon rows on the favicon styles sheet.
    let states: [SidebarStatesPlaygroundState]
    /// The sheet's title: the appearance's, or its favicon style's title.
    let title: String
    /// The cells, by column, then state.
    let cells: [SidebarStatesPlaygroundColumn: [SidebarStatesPlaygroundState: SidebarStatesPlaygroundCell]]
    /// The state names' column, from the column captions to the last row.
    private(set) var labelFrame: NSRect = .zero
    /// Each density's columns (its three text sizes), from the column captions to the last row.
    private(set) var densityFrames: [SidebarDensity: NSRect] = [:]
    /// The section under the grid with each density's pinned row and its hover card (``SidebarStatesPlaygroundState/pinnedHoverCard``),
    /// its title to its last row.
    private(set) var cardSectionFrame: NSRect = .zero
    /// The cell views, by column, then state.
    private(set) var cellViews: [SidebarStatesPlaygroundColumn: [SidebarStatesPlaygroundState: SidebarStatesPlaygroundCellView]] = [:]

    private static var margin: CGFloat { Metrics.space6 }
    private static var labelWidth: CGFloat { 180 }
    private static var columnGap: CGFloat { Metrics.space6 }
    private static var rowGap: CGFloat { Metrics.space3 }

    init(appearance: SidebarStatesPlaygroundAppearance, columns: [SidebarStatesPlaygroundColumn],
         cells: [SidebarStatesPlaygroundColumn: [SidebarStatesPlaygroundState: SidebarStatesPlaygroundCell]],
         states: [SidebarStatesPlaygroundState] = SidebarStatesPlaygroundState.allCases, title: String? = nil) {
        appearanceKind = appearance
        self.columns = columns
        self.states = states
        self.title = title ?? appearance.title
        self.cells = cells
        super.init(frame: .zero)
        self.appearance = appearance.appearance
        wantsLayer = true
        build()
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

    /// Places every label and cell; the sheet's frame is the grid's size.
    private func build() {
        let margin = Self.margin
        let columnWidth = cells.values.flatMap(\.values).filter { states.contains($0.state) && !Self.ownSection($0.state) }
            .map(\.size.width).max() ?? 260
        let gridWidth = Self.labelWidth + CGFloat(columns.count) * (columnWidth + Self.columnGap)
        var y = margin
        let title = label(self.title, font: Typography.title, color: .labelColor, at: NSPoint(x: margin, y: y), width: gridWidth)
        y = title.frame.maxY + Metrics.space2
        let legend = label(Strings.statesPlaygroundLegend, font: Typography.caption, color: .secondaryLabelColor,
                           at: NSPoint(x: margin, y: y), width: min(gridWidth, 900))
        y = legend.frame.maxY + Metrics.space5
        let gridTop = y
        func columnX(_ index: Int) -> CGFloat { margin + Self.labelWidth + CGFloat(index) * (columnWidth + Self.columnGap) }
        var captionBottom = y
        for (index, column) in columns.enumerated() {
            let caption = label(column.title, font: Typography.header, color: .labelColor, at: NSPoint(x: columnX(index), y: y), width: columnWidth)
            captionBottom = max(captionBottom, caption.frame.maxY)
        }
        y = captionBottom + Metrics.space3
        for state in states where !Self.ownSection(state) {
            var rowHeight: CGFloat = 0
            for (index, column) in columns.enumerated() {
                guard let cell = cells[column]?[state] else { continue }
                let view = SidebarStatesPlaygroundCellView(cell: cell)
                view.frame.origin = NSPoint(x: columnX(index), y: y)
                addSubview(view)
                cellViews[column, default: [:]][state] = view
                rowHeight = max(rowHeight, view.frame.height)
            }
            let name = label(state.title, font: Typography.body, color: .labelColor, at: NSPoint(x: margin, y: y), width: Self.labelWidth - Metrics.space4)
            rowHeight = max(rowHeight, name.frame.height)
            y += rowHeight + Self.rowGap
        }
        let gridBottom = y - Self.rowGap
        labelFrame = NSRect(x: margin, y: gridTop, width: Self.labelWidth, height: gridBottom - gridTop)
        for density in SidebarDensity.allCases {
            let indexes = columns.indices.filter { columns[$0].density == density }
            guard let first = indexes.first, let last = indexes.last else { continue }
            densityFrames[density] = NSRect(x: columnX(first), y: gridTop, width: columnX(last) + columnWidth - columnX(first),
                                            height: gridBottom - gridTop)
        }
        // The favicon styles sheet has no card row: its section draws on the states sheet only.
        var cardRight: CGFloat = 0
        if states.contains(.pinnedHoverCard) {
            cardRight = buildCardSection(top: y + Metrics.space5)
            y = cardSectionFrame.maxY + Self.rowGap
        }
        setFrameSize(NSSize(width: max(margin + gridWidth + margin - Self.columnGap, cardRight + margin), height: y + margin))
    }

    /// A state drawn in its own section under the grid: the pinned row's hover card is wider than a sidebar.
    private static func ownSection(_ state: SidebarStatesPlaygroundState) -> Bool { state == .pinnedHoverCard }

    /// The pinned hover card section from `top`: its title, then one row per density with its text sizes side by side,
    /// each the pinned row with its card beside it. Returns the section's right edge.
    private func buildCardSection(top: CGFloat) -> CGFloat {
        let margin = Self.margin
        let state = SidebarStatesPlaygroundState.pinnedHoverCard
        let width = cells.values.compactMap { $0[state]?.size.width }.max() ?? 0
        let title = label(state.title, font: Typography.header, color: .labelColor, at: NSPoint(x: margin, y: top),
                          width: Self.labelWidth + 3 * width)
        var y = title.frame.maxY + Metrics.space3
        var right = margin + Self.labelWidth
        for density in SidebarDensity.allCases {
            var rowHeight: CGFloat = 0
            for (index, column) in columns.filter({ $0.density == density }).enumerated() {
                guard let cell = cells[column]?[state] else { continue }
                let x = margin + Self.labelWidth + CGFloat(index) * (width + Self.columnGap)
                let caption = label(column.title, font: Typography.caption, color: .secondaryLabelColor, at: NSPoint(x: x, y: y), width: width)
                let view = SidebarStatesPlaygroundCellView(cell: cell)
                view.frame.origin = NSPoint(x: x, y: caption.frame.maxY + Metrics.space1)
                addSubview(view)
                cellViews[column, default: [:]][state] = view
                rowHeight = max(rowHeight, view.frame.maxY - y)
                right = max(right, view.frame.maxX)
            }
            let name = label(SidebarStatesPlaygroundColumn.title(density), font: Typography.body, color: .labelColor,
                             at: NSPoint(x: margin, y: y), width: Self.labelWidth - Metrics.space4)
            y += max(rowHeight, name.frame.height) + Self.rowGap
        }
        cardSectionFrame = NSRect(x: margin, y: top, width: right - margin, height: y - Self.rowGap - top)
        return right
    }
}
