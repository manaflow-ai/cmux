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

    public init(rowHeight: CGFloat, headerHeight: CGFloat, inset: CGFloat, sectionGap: CGFloat, padding: CGFloat,
                cardPadding: CGFloat, tileMinWidth: CGFloat, tileHeight: CGFloat, tileGap: CGFloat) {
        self.rowHeight = rowHeight
        self.headerHeight = headerHeight
        self.inset = inset
        self.sectionGap = sectionGap
        self.padding = padding
        self.cardPadding = cardPadding
        self.tileMinWidth = tileMinWidth
        self.tileHeight = tileHeight
        self.tileGap = tileGap
    }
}

/// One placed element of a region.
public nonisolated struct SidebarRegionRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case header(LayoutSectionID)
        case item(LayoutItemID, section: LayoutSectionID)
        /// A tile of the tray look (icon only).
        case tile(LayoutItemID, section: LayoutSectionID)
    }

    public var kind: Kind
    public var frame: CGRect
}

/// Frames of a sticky region's sections: rows, headers, tray tiles and the
/// card backgrounds. Pure, so every look is tested without views.
public nonisolated struct SidebarRegionLayout: Hashable, Sendable {
    public var rows: [SidebarRegionRow]
    /// Card backgrounds (card look only), one per section.
    public var cards: [CGRect]
    public var height: CGFloat
    /// Height of the first `maxRows` rows of each section (the content a
    /// sticky region shows before it scrolls), summed.
    public var cappedHeight: CGFloat

    public static let empty = SidebarRegionLayout(rows: [], cards: [], height: 0, cappedHeight: 0)

    public func row(at point: CGPoint) -> SidebarRegionRow? { rows.first { $0.frame.contains(point) } }

    public static func make(sections: [LayoutSection], width: CGFloat, look: SectionsLookVariant,
                            collapsed: Set<LayoutSectionID>, metrics m: SidebarRegionMetrics) -> SidebarRegionLayout {
        .empty
    }

    private static func tiles(_ section: LayoutSection, x: CGFloat, y: CGFloat, width: CGFloat,
                              metrics m: SidebarRegionMetrics) -> (rows: [SidebarRegionRow], height: CGFloat, lines: Int) {
        let count = section.items.count
        guard count > 0 else { return ([], 0, 0) }
        let fit = max(1, Int((width + m.tileGap) / (m.tileMinWidth + m.tileGap)))
        let columns = min(fit, count)
        let tileWidth = (width - CGFloat(columns - 1) * m.tileGap) / CGFloat(columns)
        var rows: [SidebarRegionRow] = []
        for (i, item) in section.items.enumerated() {
            let column = i % columns, line = i / columns
            let frame = CGRect(x: x + CGFloat(column) * (tileWidth + m.tileGap), y: y + CGFloat(line) * (m.tileHeight + m.tileGap),
                               width: tileWidth, height: m.tileHeight)
            rows.append(SidebarRegionRow(kind: .tile(item.id, section: section.id), frame: frame))
        }
        let lines = (count + columns - 1) / columns
        return (rows, CGFloat(lines) * m.tileHeight + CGFloat(lines - 1) * m.tileGap, lines)
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
