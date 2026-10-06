import CoreGraphics
import CoreText
import Foundation

/// Text measured and wrapped with Core Text, the way the bubbles draw it.
struct TextLayout: Hashable, Sendable {
    struct Line: Hashable, Sendable {
        var range: NSRange
        var width: CGFloat
        /// The line ended because the next word did not fit (not at a newline or the end).
        var softBreak: Bool
    }

    var text: String
    /// UTF-16 ranges drawn bold (mentions).
    var bold: [NSRange]
    var lines: [Line]
    /// Widest line.
    var width: CGFloat

    static func make(_ text: String, bold: [NSRange] = [], maxWidth: CGFloat, font: CTFont) -> TextLayout {
        let attr = NSAttributedString(string: text, attributes: [TextDraw.fontKey: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attr)
        let ns = text as NSString
        let length = ns.length
        var lines: [Line] = []
        var start = 0
        while start < length {
            var n = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            if n <= 0 { n = 1 }
            var range = NSRange(location: start, length: n)
            // A hard newline ends the line but is neither drawn nor measured.
            let hard = ns.character(at: start + n - 1) == 10
            if hard { range.length -= 1 }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            start += n
            lines.append(Line(range: range, width: w, softBreak: !hard && start < length))
            if start == length, hard { lines.append(Line(range: NSRange(location: length, length: 0), width: 0, softBreak: false)) }
        }
        if lines.isEmpty { lines = [Line(range: NSRange(location: 0, length: 0), width: 0, softBreak: false)] }
        return TextLayout(text: text, bold: bold, lines: lines, width: lines.map(\.width).max() ?? 0)
    }

    /// True when wrapping at `newMaxWidth` gives the same lines as wrapping
    /// at `oldMaxWidth` did: nothing was wrapped by width and the widest line
    /// still fits. A resize then keeps this layout (and the row's bitmap)
    /// without asking Core Text again.
    func isValid(atMaxWidth newMaxWidth: CGFloat, measuredAt oldMaxWidth: CGFloat) -> Bool {
        if newMaxWidth == oldMaxWidth { return true }
        if lines.contains(where: \.softBreak) { return false }
        return width <= newMaxWidth
    }

    /// Attributed text for drawing.
    func attributed(font: CTFont, color: CGColor, kern: CGFloat = Style.bodyKern) -> NSAttributedString {
        let a = NSMutableAttributedString(string: text, attributes: TextDraw.attributes(font, color, kern: kern))
        let boldFont = Fonts.withTraits(font, .traitBold)
        for range in bold where NSMaxRange(range) <= a.length {
            a.addAttribute(TextDraw.fontKey, value: boldFont, range: range)
        }
        return a
    }

    /// Offset of line `i`'s baseline from the first: `hard` after a hard
    /// newline, the line height after a wrap.
    func lineOffset(_ i: Int, hard: CGFloat = Style.lineHeight) -> CGFloat {
        var y: CGFloat = 0
        let ns = text as NSString
        for j in 1..<max(1, i + 1) where j < lines.count {
            let loc = lines[j].range.location
            let afterNewline = loc > 0 && loc <= ns.length && ns.character(at: loc - 1) == 10
            y += afterNewline ? hard : Style.lineHeight
        }
        return y
    }

    func textHeight(hard: CGFloat) -> CGFloat { lineOffset(lines.count - 1, hard: hard) + Style.lineHeight }
}
