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
            // At least one unit so the loop advances, never past the text (a NaN or zero width).
            let n = min(max(CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth)), 1), length - start)
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
        for range in bold {
            guard let inText = Self.boldRange(range, in: a.length) else { continue }
            a.addAttribute(TextDraw.fontKey, value: boldFont, range: inText)
        }
        return a
    }

    /// A mention range from the wire (any `Int`s) when it lies inside a text of `count` UTF-16 units,
    /// else nil: a run that does not fit is skipped, the Mac renderer's rule for the same data
    /// (MessagesLabHome's `TextLayout.range(_:_:in:)`). No `NSMaxRange`: `location + length` overflows.
    static func boldRange(_ range: NSRange, in count: Int) -> NSRange? {
        guard range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location else { return nil }
        return range
    }

    /// Offset of every line's baseline from the first: `hard` after a hard newline, the line height
    /// after a wrap. One pass (a walk from the first line for each line cost O(lines²) to draw).
    func lineOffsets(hard: CGFloat = Style.lineHeight) -> [CGFloat] {
        var out: [CGFloat] = []
        out.reserveCapacity(lines.count)
        forEachLineOffset(hard: hard) { out.append($0) }
        return out
    }

    func textHeight(hard: CGFloat) -> CGFloat {
        var last: CGFloat = 0
        forEachLineOffset(hard: hard) { last = $0 }
        return last + Style.lineHeight
    }

    /// The one baseline rule of ``lineOffsets(hard:)`` and ``textHeight(hard:)``, line by line.
    private func forEachLineOffset(hard: CGFloat, _ body: (CGFloat) -> Void) {
        let ns = text as NSString
        var y: CGFloat = 0
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let loc = line.range.location
                let afterNewline = loc > 0 && loc <= ns.length && ns.character(at: loc - 1) == 10
                y += afterNewline ? hard : Style.lineHeight
            }
            body(y)
        }
    }
}
