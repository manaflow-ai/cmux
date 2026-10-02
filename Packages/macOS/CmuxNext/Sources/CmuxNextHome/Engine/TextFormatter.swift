public import CoreGraphics
import CoreText
import Foundation

/// CoreText measuring and drawing for bubble and label text. Thread-safe:
/// called on the main actor for near-viewport rows and on background threads
/// for pages and rasters. Every line has the same height
/// (`TranscriptGeometry.lineHeight`), so estimates and measurements agree.
nonisolated enum TextFormatter {
    static func font(size: CGFloat, emphasized: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(emphasized ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// A paragraph style with a fixed line height (every line the same height).
    static func paragraph(lineHeight: CGFloat) -> CTParagraphStyle {
        var lh = lineHeight
        let settings = [
            CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: &lh),
            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: &lh),
        ]
        return CTParagraphStyleCreate(settings, settings.count)
    }

    /// The bubble text with mentions in the emphasized face.
    static func attributed(_ text: String, mentions: [HomeMention], fontSize: CGFloat, lineHeight: CGFloat,
                           color: CGColor?) -> NSAttributedString {
        var lh = lineHeight
        let settings = [
            CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: &lh),
            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: &lh),
        ]
        let paragraph = CTParagraphStyleCreate(settings, settings.count)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: fontSize),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        let length = string.length
        let bold = font(size: fontSize, emphasized: true)
        for mention in mentions where mention.start >= 0 && mention.length > 0 && mention.start + mention.length <= length {
            string.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: bold,
                                range: NSRange(location: mention.start, length: mention.length))
        }
        return string
    }

    /// Size of `text` wrapped at `maxWidth` (width of the widest line).
    static func measure(_ text: String, mentions: [HomeMention], fontSize: CGFloat, lineHeight: CGFloat,
                        maxWidth: CGFloat) -> CGSize {
        frameSize(attributed(text, mentions: mentions, fontSize: fontSize, lineHeight: lineHeight, color: nil),
                  lineHeight: lineHeight, maxWidth: maxWidth)
    }

    /// Size of the Markdown rendering of `text` (MarkdownFormatter).
    static func measureMarkdown(_ text: String, fontSize: CGFloat, lineHeight: CGFloat, maxWidth: CGFloat) -> CGSize {
        frameSize(MarkdownFormatter.attributed(text, fontSize: fontSize, lineHeight: lineHeight, color: nil),
                  lineHeight: lineHeight, maxWidth: maxWidth)
    }

    private static func frameSize(_ string: NSAttributedString, lineHeight: CGFloat, maxWidth: CGFloat) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let lines = max(1, (size.height / lineHeight).rounded())
        return CGSize(width: min(maxWidth, size.width.rounded(.up)), height: lines * lineHeight)
    }

    /// Draws `text` into `rect` (y-up context, origin bottom-left), wrapped at its width.
    static func draw(_ text: String, mentions: [HomeMention], fontSize: CGFloat, lineHeight: CGFloat, color: CGColor,
                     in rect: CGRect, context: CGContext) {
        drawFrame(attributed(text, mentions: mentions, fontSize: fontSize, lineHeight: lineHeight, color: color),
                  in: rect, context: context)
    }

    /// Draws the Markdown rendering of `text` into `rect` (y-up context).
    static func drawMarkdown(_ text: String, fontSize: CGFloat, lineHeight: CGFloat, color: CGColor, in rect: CGRect,
                             context: CGContext) {
        drawFrame(MarkdownFormatter.attributed(text, fontSize: fontSize, lineHeight: lineHeight, color: color),
                  in: rect, context: context)
    }

    private static func drawFrame(_ string: NSAttributedString, in rect: CGRect, context: CGContext) {
        let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let path = CGPath(rect: rect.insetBy(dx: 0, dy: -1), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    /// Width of a single-line label.
    static func lineWidth(_ text: String, size: CGFloat, emphasized: Bool) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, emphasized: emphasized),
        ]) as CFAttributedString)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
    }

    /// Draws one line with its baseline at `baseline` (y-up context).
    static func drawLine(_ text: String, size: CGFloat, emphasized: Bool, color: CGColor, x: CGFloat, baseline: CGFloat,
                         context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, emphasized: emphasized),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]) as CFAttributedString)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
    }

    /// Baseline offset from the top of a line box of `height` for a font of `size`.
    static func baseline(size: CGFloat, inLineOf height: CGFloat) -> CGFloat {
        let f = font(size: size)
        let ascent = CTFontGetAscent(f), descent = CTFontGetDescent(f)
        return ((height - (ascent + descent)) / 2 + ascent).rounded()
    }
}
