import Foundation

/// Pure layout math for the diff viewer, kept free of UIKit so it is unit tested on macOS.
///
/// Unified, unwrapped rows render as two columns: a pinned gutter (old number, new number,
/// the ± marker) and a code column inside one horizontal scroll view shared by every row.
/// Every row has a fixed height, so the two columns line up without measuring.
public enum DiffLayout {
    /// Tabs expand to this many columns (monospaced width is then exact).
    public static let tabWidth = 4
    /// The width of one line-number cell (two of them in the unified gutter).
    public static let numberWidth: CGFloat = 36
    public static let numberTrailingPadding: CGFloat = 4
    /// The ± column.
    public static let markerWidth: CGFloat = 14
    /// Trailing room after the longest line.
    public static let codeTrailingPadding: CGFloat = 16
    /// Hunk headers, gaps and "Expand N lines" rows.
    public static let headerRowHeight: CGFloat = 32
    /// Wrapped continuations never indent past this fraction of the code column.
    public static let maxIndentFraction: CGFloat = 0.5

    /// The pinned gutter: two number cells and the marker.
    public static var gutterWidth: CGFloat {
        (numberWidth + numberTrailingPadding) * 2 + markerWidth
    }

    /// A code line as displayed: tabs expanded, word highlights remapped to the expanded text.
    public struct DisplayLine: Equatable, Sendable {
        public var text: String
        public var highlights: [Range<Int>]
        /// Leading whitespace columns (after tab expansion).
        public var indent: Int
    }

    public static func display(_ line: DiffLine) -> DisplayLine {
        display(text: line.text, highlights: line.changedRanges)
    }

    /// Expands tabs and remaps character highlight ranges onto the expanded text.
    public static func display(text: String, highlights: [Range<Int>]) -> DisplayLine {
        var expanded = ""
        // map[i] = expanded offset of source character i; map[count] = expanded length.
        var map: [Int] = []
        map.reserveCapacity(text.count + 1)
        var column = 0
        for character in text {
            map.append(column)
            if character == "\t" {
                let spaces = tabWidth - column % tabWidth
                expanded += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                expanded.append(character)
                column += 1
            }
        }
        map.append(column)
        let remapped: [Range<Int>] = highlights.compactMap { range in
            guard range.lowerBound >= 0, range.upperBound <= text.count, !range.isEmpty else { return nil }
            return map[range.lowerBound]..<map[range.upperBound]
        }
        let indent = expanded.prefix { $0 == " " }.count
        return DisplayLine(text: expanded, highlights: remapped, indent: indent == expanded.count ? 0 : indent)
    }

    /// The fixed height of one unwrapped code row.
    public static func rowHeight(lineHeight: CGFloat) -> CGFloat {
        (lineHeight + 4).rounded(.up)
    }

    /// The width of the horizontally scrolled code column: the longest displayed line sets
    /// it, and it never shrinks below the visible code viewport (row backgrounds span it).
    public static func codeContentWidth(lines: [DiffLine], charWidth: CGFloat, viewport: CGFloat) -> CGFloat {
        let longest = lines.lazy.map { display($0).text.count }.max() ?? 0
        let content = (CGFloat(longest) * charWidth + codeTrailingPadding).rounded(.up)
        return max(content, codeViewport(width: viewport))
    }

    /// The visible width of the code column next to the pinned gutter.
    public static func codeViewport(width: CGFloat) -> CGFloat {
        max(0, width - gutterWidth)
    }

    /// The hanging indent (points) for a wrapped line: continuations align with the first
    /// non-space character, capped so deeply indented code still has room to wrap.
    public static func hangingIndent(_ line: DisplayLine, charWidth: CGFloat, codeWidth: CGFloat) -> CGFloat {
        min(CGFloat(line.indent) * charWidth, (codeWidth * maxIndentFraction).rounded(.down))
    }

    /// How many visual rows a wrapped line takes in a monospaced column (row-height math for
    /// wrap mode). Continuations start at the hanging indent.
    public static func wrappedRowCount(_ line: DisplayLine, charWidth: CGFloat, codeWidth: CGFloat) -> Int {
        guard charWidth > 0, codeWidth > 0 else { return 1 }
        let indent = hangingIndent(line, charWidth: charWidth, codeWidth: codeWidth)
        let columns = max(1, Int(((codeWidth - indent) / charWidth).rounded(.down)))
        let body = line.text.count - min(line.indent, Int((indent / charWidth).rounded(.down)))
        return max(1, (body + columns - 1) / columns)
    }

    /// Split view needs room for two readable columns; phones keep Unified (GitHub mobile).
    public static func allowsSplit(width: CGFloat) -> Bool {
        width >= 700
    }
}
