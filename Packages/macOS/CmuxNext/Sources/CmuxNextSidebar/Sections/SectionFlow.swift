public import CoreGraphics
import Foundation

/// Places a section's items on lines: the inline and grid arrangements
/// (and the tray and lines-icons looks). Pure.
nonisolated enum SectionFlow {
    enum Mode: Hashable {
        /// Tiles in columns (nil = as many as fit).
        case grid(columns: Int?)
        /// One line; labels while they fit unless `iconsOnly`.
        case inline(iconsOnly: Bool)
    }

    struct Result {
        var rows: [SidebarRegionRow]
        var height: CGFloat
        var lines: Int
        var lineHeight: CGFloat
        var gap: CGFloat = 0
    }

    /// The mode `section` uses in `look`, or nil for rows. Precedence: the
    /// section's own arrangement when it is inline or grid; otherwise (a
    /// list, the default) the tray and lines-icons looks tile built-in
    /// sections. The look only styles; it never overrides a choice.
    static func mode(_ section: LayoutSection, look: SectionsLookVariant) -> Mode? {
        switch section.arrangement.layout {
        case .inline: return .inline(iconsOnly: false)
        case .grid: return .grid(columns: section.arrangement.columns)
        case .list: break
        }
        switch look.tiling(section) {
        case .grid: return .grid(columns: nil)
        case .buttons: return .inline(iconsOnly: true)
        case nil: return nil
        }
    }

    /// `labelWidths`: each item's icon + label width (inline); a missing
    /// entry means icon only.
    static func place(_ section: LayoutSection, mode: Mode, x: CGFloat, y: CGFloat, width: CGFloat,
                      labelWidths: [LayoutItemID: CGFloat], metrics m: SidebarRegionMetrics) -> Result {
        let items = section.items
        guard !items.isEmpty else { return Result(rows: [], height: 0, lines: 0, lineHeight: 0) }
        var result = placeLines(section, mode: mode, x: x, y: y, width: width, labelWidths: labelWidths, metrics: m)
        result.gap = section.arrangement.gap.map { CGFloat($0) } ?? m.tileGap
        return result
    }

    private static func placeLines(_ section: LayoutSection, mode: Mode, x: CGFloat, y: CGFloat, width: CGFloat,
                                   labelWidths: [LayoutItemID: CGFloat], metrics m: SidebarRegionMetrics) -> Result {
        let items = section.items
        let gap = section.arrangement.gap.map { CGFloat($0) } ?? m.tileGap
        let align = section.arrangement.align
        switch mode {
        case let .grid(columns):
            let fit = max(1, Int((width + gap) / (m.tileMinWidth + gap)))
            let count = min(max(columns ?? fit, 1), fit)
            // Fitted columns (or fill) stretch the tiles to the width;
            // fixed columns keep the tile size and place every line by
            // the leftover of a full line, so columns line up.
            let stretched = align == .fill || columns == nil
            let tileWidth = stretched ? (width - CGFloat(count - 1) * gap) / CGFloat(count) : m.tileMinWidth
            let lines = chunk(items, count)
            return lay(lines, kind: { .tile($0, section: section.id) }, widths: { _ in tileWidth }, x: x, y: y, width: width,
                       gap: gap, align: stretched ? .leading : align, lineHeight: m.tileHeight,
                       fullLine: CGFloat(count) * (tileWidth + gap) - gap)
        case let .inline(iconsOnly):
            let icon = m.iconButtonWidth
            let chips = items.map { labelWidths[$0.id] ?? icon }
            let chipTotal = chips.reduce(0, +) + gap * CGFloat(items.count - 1)
            if !iconsOnly, chipTotal <= width {
                let byID = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), chips))
                return lay([items], kind: { labelWidths[$0] == nil ? .tile($0, section: section.id) : .chip($0, section: section.id) }, widths: { byID[$0] ?? icon }, x: x, y: y,
                           width: width, gap: gap, align: align, lineHeight: m.rowHeight)
            }
            let perLine = max(1, Int((width + gap) / (icon + gap)))
            return lay(chunk(items, perLine), kind: { .tile($0, section: section.id) }, widths: { _ in icon }, x: x, y: y,
                       width: width, gap: gap, align: align, lineHeight: m.rowHeight)
        }
    }

    private static func chunk(_ items: [LayoutItem], _ size: Int) -> [[LayoutItem]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    private static func lay(_ lines: [[LayoutItem]], kind: (LayoutItemID) -> SidebarRegionRow.Kind, widths: (LayoutItemID) -> CGFloat,
                            x: CGFloat, y: CGFloat, width: CGFloat, gap: CGFloat, align: SectionArrangement.Alignment,
                            lineHeight: CGFloat, fullLine: CGFloat? = nil) -> Result {
        var rows: [SidebarRegionRow] = []
        for (index, line) in lines.enumerated() {
            let w = line.map { widths($0.id) }
            let used = fullLine ?? (w.reduce(0, +) + gap * CGFloat(max(0, line.count - 1)))
            let leftover = max(0, width - used)
            var cursor: CGFloat
            var spacing = gap
            // Where fill puts all of the leftover, between labeled chips and
            // the icon-only tiles after them.
            var split: Int?
            switch align {
            case .leading: cursor = x
            case .center: cursor = x + leftover / 2
            case .trailing: cursor = x + leftover
            case .fill:
                cursor = x
                // Labeled items stay leading and icon-only items after them
                // group at the trailing edge (Settings, then the studio and
                // the avatar); otherwise two or more spread to both edges
                // and one stays leading.
                let tiles = line.map { if case .tile = kind($0.id) { true } else { false } }
                if let first = tiles.firstIndex(of: true), first > 0, !tiles[first...].contains(false) {
                    split = first
                } else if line.count > 1 {
                    spacing = gap + leftover / CGFloat(line.count - 1)
                }
            }
            let lineY = y + CGFloat(index) * (lineHeight + gap)
            for (position, (item, itemWidth)) in zip(line, w).enumerated() {
                if position == split { cursor += leftover }
                rows.append(SidebarRegionRow(kind: kind(item.id), frame: CGRect(x: cursor, y: lineY, width: itemWidth, height: lineHeight)))
                cursor += itemWidth + spacing
            }
        }
        let height = CGFloat(lines.count) * lineHeight + CGFloat(max(0, lines.count - 1)) * gap
        return Result(rows: rows, height: height, lines: lines.count, lineHeight: lineHeight)
    }
}
