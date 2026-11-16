#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Lays out a bubble's Markdown tables (``ConversationTextTable``) as columns:
/// each row is one line of tab-separated cells, so a tab stop per column puts
/// every cell under its header, aligned as the table's delimiter row says.
/// Applied after the text's fonts are set, since cells are measured in them.
enum ConversationTableLayout {
    /// Space between two columns, as a multiple of the font's point size.
    static let columnGapEms: CGFloat = 1

    static func apply(_ tables: [ConversationTextTable], to text: NSMutableAttributedString, font: UIFont) {
        let gap = (font.pointSize * columnGapEms).rounded(.up)
        let source = text.string as NSString
        for table in tables where NSMaxRange(table.range) <= text.length && !table.alignments.isEmpty {
            let columns = table.alignments.count
            let leadingTab = table.alignments[0] != .leading
            // Every row's cells, as ranges in `text`.
            var rows: [(line: NSRange, cells: [NSRange])] = []
            source.enumerateSubstrings(in: table.range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
                var cells: [NSRange] = []
                var start = line.location
                for index in line.location..<NSMaxRange(line) where source.character(at: index) == 9 {
                    cells.append(NSRange(location: start, length: index - start))
                    start = index + 1
                }
                cells.append(NSRange(location: start, length: NSMaxRange(line) - start))
                if leadingTab, !cells.isEmpty { cells.removeFirst() }
                rows.append((line, cells))
            }
            var widths = [CGFloat](repeating: 0, count: columns)
            for row in rows {
                for (column, cell) in row.cells.prefix(columns).enumerated() where cell.length > 0 {
                    let size = text.attributedSubstring(from: cell).boundingRect(
                        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                    ).size
                    widths[column] = max(widths[column], ceil(size.width))
                }
            }
            var stops: [NSTextTab] = []
            var x: CGFloat = 0
            for column in 0..<columns {
                let alignment = table.alignments[column]
                if column > 0 || leadingTab {
                    switch alignment {
                    case .leading: stops.append(NSTextTab(textAlignment: .natural, location: x))
                    case .center: stops.append(NSTextTab(textAlignment: .center, location: x + widths[column] / 2))
                    case .trailing: stops.append(NSTextTab(textAlignment: .right, location: x + widths[column]))
                    }
                }
                x += widths[column] + gap
            }
            for (index, row) in rows.enumerated() {
                let paragraph = NSRange(location: row.line.location, length: min(text.length, NSMaxRange(row.line) + 1) - row.line.location)
                let base = (text.attribute(.paragraphStyle, at: row.line.location, effectiveRange: nil) as? NSParagraphStyle) ?? NSParagraphStyle()
                let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.tabStops = stops
                style.defaultTabInterval = gap
                // A row wider than the bubble (large text sizes) wraps, so no cell is cut.
                style.lineBreakMode = .byWordWrapping
                // A little air under the header row.
                if index == 0, rows.count > 1 { style.paragraphSpacing = max(style.paragraphSpacing, (font.pointSize / 4).rounded()) }
                text.addAttribute(.paragraphStyle, value: style, range: paragraph)
            }
        }
    }
}
#endif
