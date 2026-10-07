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
    /// Height of one large labeled tile (the tiles arrangement).
    public var favoriteHeight: CGFloat
    /// Where the rows' glyphs sit, from a line's leading edge. When set, a
    /// line of icon-only items (the footer's avatar and gear) is
    /// row-height squares with no gap (unless the section sets one), the
    /// first glyph on this column (SIDEBAR-FOOTER-AND-SPACE-MENU F1). Nil
    /// keeps `iconButtonWidth` and `tileGap`.
    public var glyphColumn: CGFloat?

    public init(rowHeight: CGFloat, headerHeight: CGFloat, inset: CGFloat, sectionGap: CGFloat, padding: CGFloat,
                cardPadding: CGFloat, tileMinWidth: CGFloat, tileHeight: CGFloat, tileGap: CGFloat,
                iconButtonWidth: CGFloat? = nil, lineWidth: CGFloat = 1, favoriteHeight: CGFloat? = nil,
                glyphColumn: CGFloat? = nil) {
        self.glyphColumn = glyphColumn
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
        self.favoriteHeight = favoriteHeight ?? rowHeight * 2 + tileGap
    }
}

/// One placed element of a region.
public nonisolated struct SidebarRegionRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case header(LayoutSectionID)
        case item(LayoutItemID, section: LayoutSectionID)
        /// An icon-only item: a grid tile or an inline icon button.
        case tile(LayoutItemID, section: LayoutSectionID)
        /// An inline item with icon and label.
        case chip(LayoutItemID, section: LayoutSectionID)
        /// The content of an app's section (`SectionContent.app`).
        case app(LayoutSectionID)
    }

    public var kind: Kind
    public var frame: CGRect
}

/// Frames of a pinned region's sections: rows, headers, icon tiles, card
/// backgrounds, section lines and each section's full frame. Pure, so
/// every look is tested without views.
public nonisolated struct SidebarRegionLayout: Hashable, Sendable {
    public var rows: [SidebarRegionRow]
    /// Card backgrounds (card look only), one per section.
    public var cards: [CGRect]
    /// Indices into `cards` of tiles sections, which take a stronger step.
    public var tiledCards: Set<Int> = []
    /// Lines between sections (lines looks).
    public var separators: [CGRect]
    /// Each shown section's full-width frame, in order (the tonal step
    /// under `appearance.borders = none`).
    public var sectionFrames: [CGRect]
    public var height: CGFloat
    /// Height of the first `maxRows` rows of each section (the content a
    /// pinned region shows before it scrolls), summed.
    public var cappedHeight: CGFloat

    public static let empty = SidebarRegionLayout(rows: [], cards: [], separators: [], sectionFrames: [], height: 0, cappedHeight: 0)

    public func row(at point: CGPoint) -> SidebarRegionRow? { rows.first { $0.frame.contains(point) } }

    public static func make(sections: [LayoutSection], width: CGFloat, look: SectionsLookVariant,
                            collapsed: Set<LayoutSectionID>, metrics m: SidebarRegionMetrics,
                            labelWidths: [LayoutItemID: CGFloat] = [:], appHeights: [LayoutSectionID: CGFloat] = [:],
                            iconWidths: [LayoutItemID: CGFloat] = [:]) -> SidebarRegionLayout {
        // An app section shows only with content (a height from its provider).
        let shown = sections.filter { section in
            switch section.content {
            case .items: !section.items.isEmpty || header(section, look) != nil
            case .app: (appHeights[section.id] ?? 0) > 0
            default: false
            }
        }
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
            // A tiles section sits on its own card in every look: the tonal
            // step, plus a section gap below it, sets it apart from the list.
            let tiled = if case .tiles = SectionFlow.mode(section, look: look) { true } else { false }
            let carded = look == .card || tiled
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
                if section.content == .app, let height = appHeights[section.id] {
                    result.rows.append(SidebarRegionRow(kind: .app(section.id), frame: CGRect(x: x, y: y, width: innerWidth, height: height)))
                    y += height
                    sectionCapped += height
                } else if let mode = SectionFlow.mode(section, look: look) {
                    let flowInset = tiled ? m.cardPadding : m.inset
                    let flow = SectionFlow.place(section, mode: mode, x: x + flowInset, y: y, width: max(0, innerWidth - flowInset * 2),
                                                 labelWidths: labelWidths, iconWidths: iconWidths, metrics: m)
                    result.rows += flow.rows
                    y += flow.height
                    let lines = min(flow.lines, section.maxRows ?? flow.lines)
                    sectionCapped += CGFloat(lines) * flow.lineHeight + CGFloat(max(0, lines - 1)) * flow.gap
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
                if tiled { result.tiledCards.insert(result.cards.count) }
                result.cards.append(CGRect(x: x, y: top, width: innerWidth, height: y - top))
            }
            result.sectionFrames.append(CGRect(x: 0, y: top, width: width, height: y - top))
            capped += sectionCapped
            if tiled {
                y += m.sectionGap
                capped += m.sectionGap
            }
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

    /// The height a pinned region takes: its content, capped by the
    /// sections' `maxRows` and by `share` of the sidebar's `available`
    /// height. Beyond that the region scrolls inside.
    public func pinnedHeight(available: CGFloat, share: CGFloat) -> CGFloat {
        min(cappedHeight, max(0, available * share))
    }
}

extension SidebarLayoutDocument {
    /// The item sections drawn above and below the workspace list in
    /// `room`, in region order (top, middle, bottom) split at the
    /// workspaces section. Items sections in the middle region draw in the
    /// band next to the list. Pure, so the rail's nonisolated layout reads
    /// it too. The middle sections after the list (`listTrail`) draw in the
    /// list itself, not in the band below.
    public nonisolated func bands(room: String?) -> (above: [LayoutSection], below: [LayoutSection]) {
        let ordered = SidebarRegion.allCases.flatMap { sections(in: $0, room: room) }
        guard let split = ordered.firstIndex(where: { $0.content == .workspaces }) else { return (ordered, []) }
        return (Array(ordered[..<split]), Array(ordered[(split + 1)...]))
    }

    /// The middle sections after the workspaces (Recents): they draw right
    /// under the list's last row and scroll with it, one sidebar with no gap
    /// (Leo 2026-10-06). The bottom region stays pinned under the list.
    public nonisolated func listTrail(room: String?) -> [LayoutSection] {
        let middle = sections(in: .middle, room: room)
        guard let split = middle.firstIndex(where: { $0.content == .workspaces }) else { return [] }
        return Array(middle[(split + 1)...])
    }
}

extension Array where Element == LayoutSection {
    /// These sections without the items in `hidden` (items that draw
    /// nothing, such as a hidden app's); the layout keeps them.
    public func hidingItems(_ hidden: Set<LayoutItemID>) -> [LayoutSection] {
        presenting(hidingItems: hidden, apps: [])
    }

    /// What draws: no section and no item of a suppressed app (no
    /// placeholder either: hiding an app is a choice, not an error), and no
    /// item in `hidden`. The layout keeps every place, so unhiding an app
    /// brings its sections and items back where they were.
    public func presenting(hidingItems hidden: Set<LayoutItemID>, apps: Set<String>) -> [LayoutSection] {
        guard !hidden.isEmpty || !apps.isEmpty else { return self }
        return compactMap { section in
            if let app = section.owningAppID, apps.contains(app) { return nil }
            var section = section
            section.items.removeAll { hidden.contains($0.id) || $0.owningAppID.map(apps.contains) == true }
            return section
        }
    }
}
