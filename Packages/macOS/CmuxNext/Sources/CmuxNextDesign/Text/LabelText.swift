import AppKit

/// The text layout of ``ChromeLabel`` (cx-8w027.26): one TextKit stack, shared by every label on
/// the main thread, lays a label's text out for its size, its baselines and its glyphs.
///
/// It lays out as a label field does (measured against `NSTextField` on macOS 26 and 27 by
/// `debug.label_parity`): the text sits 2 pt in from each side (the line fragment padding; the
/// field's alignment rect excludes it), the first line at the top edge, each line as tall as its
/// font's ascender rounded to a whole point and its descender rounded up to one, widths
/// rounded up to a whole pixel. Only a
/// wrapping label (``Shape/wraps``) breaks lines at the width, up to its line count, the line
/// break mode on its last line; any other label shows each of its lines whole, clipped or
/// truncated at the width.
enum LabelText {
    /// The settings that shape the lines (not the color).
    struct Shape: Equatable {
        var lines: Int
        var wraps: Bool
        var lineBreak: NSLineBreakMode
        var alignment: NSTextAlignment
        var tightens: Bool
        var truncatesLastVisibleLine: Bool
        /// A wrapping label's keeps a lone word off its last line (push out); a plain label's does not.
        var strategy: NSParagraphStyle.LineBreakStrategy

        /// The lines break at the width: a wrapping label allowed more than one line.
        var isMultiline: Bool { wraps && lines != 1 }
    }

    /// A laid-out text: its size in the alignment rect (no padding) and its baselines.
    struct Metrics: Equatable {
        var size: NSSize
        var firstBaseline: CGFloat
        var lastBaselineFromBottom: CGFloat
    }

    nonisolated static let padding: CGFloat = 2

    private static let storage = NSTextStorage()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = padding
        return container
    }()
    private static let lineHeights = WholePointLines()
    private static let manager: NSLayoutManager = {
        let manager = NSLayoutManager()
        manager.delegate = lineHeights
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return manager
    }()

    /// `content` with `font` on the runs that have none and `color` (if any) on the runs that have none,
    /// and the UI font's tracking on its runs (`BundledFonts.tracked`).
    static func styled(_ content: NSAttributedString, font: NSFont?, color: NSColor?) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: content)
        let all = NSRange(location: 0, length: text.length)
        let base = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        text.enumerateAttribute(.font, in: all) { value, range, _ in
            if value == nil { text.addAttribute(.font, value: base, range: range) }
        }
        if let color {
            text.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
                if value == nil { text.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        return BundledFonts.tracked(text)
    }

    /// `text` with the paragraph settings of `shape`: alignment (a run's own wins over
    /// `.natural`), the line break of a line, tightening.
    static func paragraphed(_ text: NSAttributedString, shape: Shape) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: result.length)
        let lineBreak: NSLineBreakMode = shape.wraps ? (shape.lineBreak == .byCharWrapping ? .byCharWrapping : .byWordWrapping) : shape.lineBreak
        result.enumerateAttribute(.paragraphStyle, in: all) { value, range, _ in
            let own = value as? NSParagraphStyle
            let style = (own ?? .default).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            if own == nil || shape.alignment != .natural { style.alignment = shape.alignment }
            style.lineBreakMode = lineBreak
            if own == nil { style.lineBreakStrategy = shape.strategy }
            style.allowsDefaultTighteningForTruncation = shape.tightens
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    /// Sets `container` up for `shape` in a box `width` wide (nil: unbounded, padding included).
    static func configure(_ container: NSTextContainer, shape: Shape, width: CGFloat?, height: CGFloat?) {
        container.lineFragmentPadding = padding
        // A wrapping label stops at its line count; any other label shows every line it has.
        container.maximumNumberOfLines = shape.wraps ? max(shape.lines, 0) : 0
        // A wrapping label whose last visible line truncates ends it in an ellipsis.
        container.lineBreakMode = !shape.wraps ? .byClipping : shape.truncatesLastVisibleLine && isWrapping(shape.lineBreak) ? .byTruncatingTail : shape.lineBreak
        let size = NSSize(width: width ?? .greatestFiniteMagnitude, height: height ?? .greatestFiniteMagnitude)
        if container.size != size { container.size = size }
    }

    /// The height a drawing at `size` lays out in: the frame for a label whose last visible line
    /// truncates, else unbounded (the view clips).
    static func layoutHeight(_ shape: Shape, size: NSSize) -> CGFloat? {
        shape.wraps && shape.truncatesLastVisibleLine ? size.height : nil
    }

    private static func isWrapping(_ mode: NSLineBreakMode) -> Bool { mode == .byWordWrapping || mode == .byCharWrapping }

    /// The layout of `text` (font set, no paragraph settings yet) with `width` points for the
    /// text (nil: unbounded), at `scale` pixels per point.
    static func measure(_ text: NSAttributedString, font: NSFont?, shape: Shape, width: CGFloat?, scale: CGFloat) -> Metrics {
        // Alignment moves lines, not their breaks or heights: measure left-aligned, so an
        // unbounded width keeps the lines at the left edge.
        var measuring = shape
        measuring.alignment = .left
        // A field measures its lines whole; only its drawing truncates the last visible one.
        measuring.truncatesLastVisibleLine = false
        // An empty label is one empty line of its font.
        let shown = text.length > 0 ? text
            : NSAttributedString(string: " ", attributes: [.font: font ?? .systemFont(ofSize: NSFont.systemFontSize)])
        // A field measures the lines it shows: its first `lines` lines, laid out as if unlimited
        // (a limited container sets the rest of the text on its last line).
        let shownLines = measuring.wraps && measuring.lines > 0 ? measuring.lines : Int.max
        if measuring.wraps { measuring.lines = 0 }
        let range = lay(paragraphed(shown, shape: measuring), shape: measuring, width: width.map { $0 + padding * 2 }, height: nil)
        guard range.length > 0 else { return Metrics(size: .zero, firstBaseline: 0, lastBaselineFromBottom: 0) }
        var used = CGRect.null
        var baselines: [CGFloat] = []
        manager.enumerateLineFragments(forGlyphRange: range) { rect, usedRect, _, glyphs, stop in
            baselines.append(rect.minY + reportedAscent(of: glyphs))
            let last = baselines.count >= shownLines
            // The last line a field shows, when more text follows it, ends at its last visible
            // glyph: its trailing spaces do not count (they push a full line to the edge).
            used = used.union(last && NSMaxRange(glyphs) < NSMaxRange(range) ? withoutTrailingSpaces(usedRect, glyphs: glyphs) : usedRect)
            if last { stop.pointee = true }
        }
        // The extra line after a final line break counts too, as a field's.
        if shownLines == Int.max, !manager.extraLineFragmentUsedRect.isEmpty { used = used.union(manager.extraLineFragmentUsedRect) }
        let scale = max(scale, 1)
        let textWidth = text.length > 0 ? max(used.maxX - padding * 2, 0) : 0
        let size = NSSize(width: (textWidth * scale).rounded(.up) / scale, height: (used.maxY * scale).rounded(.up) / scale)
        return Metrics(size: size, firstBaseline: baselines.first ?? 0, lastBaselineFromBottom: size.height - (baselines.last ?? 0))
    }

    /// `usedRect` of the laid-out line `glyphs` without its trailing spaces, tabs and line break:
    /// its right edge at the right edge of the glyphs before them (a field measures "short   \n"
    /// as "short"). A line whose kept glyphs reach as far right keeps its rect (right-to-left
    /// text, where the trailing spaces sit on the left).
    private static func withoutTrailingSpaces(_ usedRect: CGRect, glyphs: NSRange) -> CGRect {
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let string = storage.string as NSString
        var end = NSMaxRange(characters)
        while end > characters.location, [0x20, 0x09, 0x0A, 0x0D, 0x2028, 0x2029].contains(string.character(at: end - 1)) { end -= 1 }
        guard end < NSMaxRange(characters), end > characters.location else { return usedRect }
        let kept = manager.glyphRange(forCharacterRange: NSRange(location: characters.location, length: end - characters.location),
                                      actualCharacterRange: nil)
        let right = manager.boundingRect(forGlyphRange: kept, in: container).maxX + padding
        guard right > usedRect.minX, right < usedRect.maxX else { return usedRect }
        return CGRect(x: usedRect.minX, y: usedRect.minY, width: right - usedRect.minX, height: usedRect.height)
    }

    /// `text` up to the end of its last visible line with an ellipsis in place of the line
    /// break there, when the label truncates its last visible line, the layout (`glyphs`) shows
    /// only part of the text and the cut falls on a line break; else nil.
    private static func ellipsized(_ text: NSAttributedString, shape: Shape, glyphs: NSRange) -> NSAttributedString? {
        guard shape.wraps, shape.truncatesLastVisibleLine else { return nil }
        let shown = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let end = NSMaxRange(shown)
        guard end < text.length, end > 0 else { return nil }
        let characters = text.string as NSString
        let last = characters.character(at: end - 1)
        guard last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029 else { return nil }
        let cut = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: 0, length: end - 1)))
        let attributes = end >= 2 ? text.attributes(at: end - 2, effectiveRange: nil) : text.attributes(at: 0, effectiveRange: nil)
        cut.append(NSAttributedString(string: "\u{2026}", attributes: attributes))
        return cut
    }

    /// The baseline a field reports for a line: its tallest font's ascender, rounded to a whole
    /// point (where the line's glyphs sit).
    private static func reportedAscent(of glyphs: NSRange) -> CGFloat {
        WholePointLines.metrics(of: lineHeights.fonts ?? storage, in: manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))?.ascent ?? 0
    }

    /// Draws `text` (font and color set) laid out for `shape` in a top-down box of `size` (the
    /// view's bounds, padding included) at the origin of the current (flipped) graphics context
    /// `context`. As a field draws them, text of more than one line clips to the text's area (the
    /// padding stays clear) and a single line to the box.
    static func draw(_ text: NSAttributedString, shape: Shape, in size: NSSize, context: CGContext) {
        let laid = paragraphed(text, shape: shape)
        var range = lay(laid, shape: shape, width: size.width, height: layoutHeight(shape, size: size))
        guard range.length > 0 else { return }
        // A last visible line cut at a line break ends in an ellipsis too, as a field's (TextKit
        // truncates only a line that runs past the width).
        if let cut = ellipsized(laid, shape: shape, glyphs: range) {
            range = lay(cut, shape: shape, width: size.width, height: layoutHeight(shape, size: size))
        }
        context.saveGState()
        defer { context.restoreGState() }
        if manager.lineFragmentRect(forGlyphAt: NSMaxRange(range) - 1, effectiveRange: nil).minY > 0 {
            context.clip(to: CGRect(x: padding, y: 0, width: max(size.width - padding * 2, 0), height: size.height))
        }
        manager.drawGlyphs(forGlyphRange: range, at: .zero)
    }

    /// The layout manager delegate that sets every line as a label field does (measured on macOS
    /// 27 at 10.5, 11, 12 and 13 pt): the baseline at its font's ascender rounded to a whole point,
    /// the descender below it rounded up to a whole point (TextKit rounds the raw sum instead: an
    /// 11 pt line is 13 pt, a field's 14 pt).
    nonisolated final class WholePointLines: NSObject, NSLayoutManagerDelegate {
        /// The text with the fonts it was given: a line is as tall as those fonts, not as the
        /// fallback fonts the text system puts in for scripts they lack (a field's Hebrew line
        /// at 13 pt is 16 pt, as a Latin one). nil: the laid-out storage's fonts.
        var fonts: NSAttributedString?

        /// The rounded ascent and the line height of the fonts of `text` in `range`; nil without a font.
        static func metrics(of text: NSAttributedString, in range: NSRange) -> (ascent: CGFloat, height: CGFloat)? {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
            text.enumerateAttribute(.font, in: range) { value, _, _ in
                guard let font = value as? NSFont else { return }
                ascent = max(ascent, font.ascender.rounded())
                descent = max(descent, (-font.descender).rounded(.up))
                leading = max(leading, font.leading.rounded(.up))
            }
            return ascent > 0 ? (ascent, ascent + descent + leading) : nil
        }

        func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                           lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                           in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
            guard let storage = layoutManager.textStorage else { return false }
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard let metrics = Self.metrics(of: fonts ?? storage, in: characters) else { return false }
            let ascent = metrics.ascent, height = metrics.height
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = ascent
            return true
        }
    }


    /// Lays `text` out in the shared stack and returns the glyphs that fit.
    private static func lay(_ text: NSAttributedString, shape: Shape, width: CGFloat?, height: CGFloat?) -> NSRange {
        let manager = Self.manager // wires the storage, the manager and the container on first use
        configure(container, shape: shape, width: width, height: height)
        lineHeights.fonts = text
        storage.setAttributedString(text)
        manager.ensureLayout(for: container)
        return manager.glyphRange(for: container)
    }
}

/// The text view over a ``ChromeLabel`` while its text is selected: the same text and layout,
/// selectable (copy), not editable.
final class LabelSelectionView: NSTextView {
    /// Runs once the view stops being first responder; the label then removes it.
    var didResign: (() -> Void)?
    /// The text system: the text view does not keep its own storage.
    private var text: NSTextStorage?
    /// The line heights of this view's text (the layout manager keeps its delegate weakly).
    private var lineHeights: LabelText.WholePointLines?

    convenience init(text: NSAttributedString, shape: LabelText.Shape, size: NSSize) {
        let laid = LabelText.paragraphed(text, shape: shape)
        let storage = NSTextStorage(attributedString: laid)
        let manager = NSLayoutManager()
        let lineHeights = LabelText.WholePointLines()
        lineHeights.fonts = laid
        manager.delegate = lineHeights
        let container = NSTextContainer(size: .zero)
        LabelText.configure(container, shape: shape, width: size.width, height: LabelText.layoutHeight(shape, size: size))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        self.init(frame: NSRect(origin: .zero, size: size), textContainer: container)
        self.text = storage
        self.lineHeights = lineHeights
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        allowsUndo = false
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { didResign?() }
        return resigned
    }
}
