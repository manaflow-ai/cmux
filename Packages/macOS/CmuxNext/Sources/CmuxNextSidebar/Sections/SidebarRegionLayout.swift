public import CoreGraphics
import Foundation

/// Sizes the region layout reads; filled from `Metrics` at layout time so
/// density changes apply, and fixed in tests.
public nonisolated struct SidebarRegionMetrics: Hashable, Sendable {
    public var rowHeight: CGFloat
    public var headerHeight: CGFloat
    public var inset: CGFloat
    public var sectionGap: CGFloat
    public var padding: CGFloat
    public var cardPadding: CGFloat
    public var tileMinWidth: CGFloat
    public var tileHeight: CGFloat
    public var tileGap: CGFloat
    /// Width of one icon button (lines-icons look).
    public var iconButtonWidth: CGFloat
    /// Thickness of a section line (lines looks).
    public var lineWidth: CGFloat

    public init(rowHeight: CGFloat, headerHeight: CGFloat, inset: CGFloat, sectionGap: CGFloat, padding: CGFloat,
                cardPadding: CGFloat, tileMinWidth: CGFloat, tileHeight: CGFloat, tileGap: CGFloat,
                iconButtonWidth: CGFloat? = nil, lineWidth: CGFloat = 1) {
        self.rowHeight = rowHeight
        self.headerHeight = headerHeight
        self.inset = inset
        self.sectionGap = sectionGap
        self.padding = padding
        self.cardPadding = cardPadding
        self.tileMinWidth = tileMinWidth
        self.tileHeight = tileHeight
        self.tileGap = tileGap
        self.iconButtonWidth = iconButtonWidth ?? rowHeight
        self.lineWidth = lineWidth
    }
}

/// One placed element of a region.
public nonisolated struct SidebarRegionRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case header(LayoutSectionID)
        case item(LayoutItemID, section: LayoutSectionID)
        /// An icon-only item: a tray tile or a lines-icons button.
        case tile(LayoutItemID, section: LayoutSectionID)
    }

    public var kind: Kind
    public var frame: CGRect
}

/// Frames of a sticky region's sections: rows, headers, icon tiles, card
/// backgrounds, section lines and each section's full frame. Pure, so
/// every look is tested without views.
public nonisolated struct SidebarRegionLayout: Hashable, Sendable {
    public var rows: [SidebarRegionRow]
    /// Card backgrounds (card look only), one per section.
    public var cards: [CGRect]
    /// Lines between sections (lines looks).
    public var separators: [CGRect]
    /// Each shown section's full-width frame, in order (the tonal step
    /// under `appearance.borders = none`).
    public var sectionFrames: [CGRect]
    public var height: CGFloat
    /// Height of the first `maxRows` rows of each section (the content a
    /// sticky region shows before it scrolls), summed.
    public var cappedHeight: CGFloat

    public static let empty = SidebarRegionLayout(rows: [], cards: [], separators: [], sectionFrames: [], height: 0, cappedHeight: 0)

    public func row(at point: CGPoint) -> SidebarRegionRow? { rows.first { $0.frame.contains(point) } }

    public static func make(sections: [LayoutSection], width: CGFloat, look: SectionsLookVariant,
                            collapsed: Set<LayoutSectionID>, metrics m: SidebarRegionMetrics) -> SidebarRegionLayout {
        let shown = sections.filter { $0.content == .items && (!$0.items.isEmpty || header($0, look) != nil) }
        guard !shown.isEmpty else { return .empty }
        var result = SidebarRegionLayout.empty
        var y = m.padding
        var capped = m.padding
        for (index, section) in shown.enumerated() {
            if index > 0 {
                if look.separatesSections {
                    result.separators.append(CGRect(x: 0, y: y + (m.sectionGap - m.lineWidth) / 2, width: width, height: m.lineWidth))
                }
                y += m.sectionGap
                capped += m.sectionGap
            }
            let carded = look == .card
            let x = carded ? m.inset : 0
            let innerWidth = max(0, width - x * 2)
            let top = y
            if carded { y += m.cardPadding }
            var sectionCapped: CGFloat = carded ? m.cardPadding * 2 : 0
            let title = header(section, look)
            if title != nil {
                result.rows.append(SidebarRegionRow(kind: .header(section.id), frame: CGRect(x: x, y: y, width: innerWidth, height: m.headerHeight)))
                y += m.headerHeight
                sectionCapped += m.headerHeight
            }
            if !(title != nil && collapsed.contains(section.id)) {
                if let tiling = look.tiling(section) {
                    let grid = tiles(section, x: x + m.inset, y: y, width: max(0, innerWidth - m.inset * 2), tiling: tiling, metrics: m)
                    result.rows += grid.rows
                    y += grid.height
                    let lines = min(grid.lines, section.maxRows ?? grid.lines)
                    sectionCapped += CGFloat(lines) * grid.lineHeight + CGFloat(max(0, lines - 1)) * m.tileGap
                } else {
                    for item in section.items {
                        result.rows.append(SidebarRegionRow(kind: .item(item.id, section: section.id),
                                                            frame: CGRect(x: x, y: y, width: innerWidth, height: m.rowHeight)))
                        y += m.rowHeight
                    }
                    sectionCapped += CGFloat(min(section.items.count, section.maxRows ?? section.items.count)) * m.rowHeight
                }
            }
            if carded {
                y += m.cardPadding
                result.cards.append(CGRect(x: x, y: top, width: innerWidth, height: y - top))
            }
            result.sectionFrames.append(CGRect(x: 0, y: top, width: width, height: y - top))
            capped += sectionCapped
        }
        y += m.padding
        capped += m.padding
        result.height = y
        result.cappedHeight = min(capped, y)
        return result
    }

    /// The header a section draws in `look`, or nil.
    static func header(_ section: LayoutSection, _ look: SectionsLookVariant) -> String? {
        look.showsHeaders ? section.headerTitle : nil
    }

    private static func tiles(_ section: LayoutSection, x: CGFloat, y: CGFloat, width: CGFloat, tiling: SectionsLookVariant.Tiling,
                              metrics m: SidebarRegionMetrics) -> (rows: [SidebarRegionRow], height: CGFloat, lines: Int, lineHeight: CGFloat) {
        let count = section.items.count
        guard count > 0 else { return ([], 0, 0, 0) }
        let minWidth = tiling == .grid ? m.tileMinWidth : m.iconButtonWidth
        let lineHeight = tiling == .grid ? m.tileHeight : m.rowHeight
        // Fixed columns, so one tile keeps its size and sits leading.
        let columns = max(1, Int((width + m.tileGap) / (minWidth + m.tileGap)))
        let tileWidth = tiling == .grid ? (width - CGFloat(columns - 1) * m.tileGap) / CGFloat(columns) : m.iconButtonWidth
        var rows: [SidebarRegionRow] = []
        for (i, item) in section.items.enumerated() {
            let column = i % columns, line = i / columns
            let frame = CGRect(x: x + CGFloat(column) * (tileWidth + m.tileGap), y: y + CGFloat(line) * (lineHeight + m.tileGap),
                               width: tileWidth, height: lineHeight)
            rows.append(SidebarRegionRow(kind: .tile(item.id, section: section.id), frame: frame))
        }
        let lines = (count + columns - 1) / columns
        return (rows, CGFloat(lines) * lineHeight + CGFloat(lines - 1) * m.tileGap, lines, lineHeight)
    }

    /// The height a sticky region takes: its content, capped by the
    /// sections' `maxRows` and by `share` of the sidebar's `available`
    /// height. Beyond that the region scrolls inside.
    public func stickyHeight(available: CGFloat, share: CGFloat) -> CGFloat {
        min(cappedHeight, max(0, available * share))
    }
}

extension SidebarLayoutDocument {
    /// The item sections drawn above and below the workspace list in
    /// `room`, in region order (top, middle, bottom) split at the
    /// workspaces section. Items sections in the middle region draw in the
    /// band next to the list; they scroll with it in phase 5
    /// (plans/cmux-next/sidebar-sections.md 8).
    public func bands(room: String?) -> (above: [LayoutSection], below: [LayoutSection]) {
        let ordered = SidebarRegion.allCases.flatMap { sections(in: $0, room: room) }
        guard let split = ordered.firstIndex(where: { $0.content == .workspaces }) else { return (ordered, []) }
        return (Array(ordered[..<split]), Array(ordered[(split + 1)...]))
    }
}
