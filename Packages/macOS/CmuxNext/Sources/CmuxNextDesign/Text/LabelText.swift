import AppKit

/// The text layout of ``ChromeLabel`` (cx-8w027.26): one TextKit stack, shared by every label on
/// the main thread, lays a label's text out for its size, its baselines and its glyphs.
///
/// It lays out as a label field does (measured against `NSTextField` on macOS 26 and 27 by
/// `debug.label_parity`): the text sits 2 pt in from each side (the line fragment padding; the
/// field's alignment rect excludes it), the first line at the top edge, each line as tall as its
/// font's ascender and descender each rounded up to a whole point, widths rounded up to a
/// whole pixel. Only a
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

        /// The lines break at the width: a wrapping label allowed more than one line.
        var isMultiline: Bool { wraps && lines != 1 }
    }

    /// A laid-out text: its size in the alignment rect (no padding) and its baselines.
    struct Metrics: Equatable {
        var size: NSSize
        var firstBaseline: CGFloat
        var lastBaselineFromBottom: CGFloat
    }

    static let padding: CGFloat = 2

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

    /// `content` with `font` on the runs that have none and `color` (if any) on the runs that have none.
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
        return text
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
        container.lineBreakMode = shape.wraps ? shape.lineBreak : .byClipping
        let size = NSSize(width: width ?? .greatestFiniteMagnitude, height: height ?? .greatestFiniteMagnitude)
        if container.size != size { container.size = size }
    }

    /// The height a drawing at `size` lays out in: the frame for a label whose last visible line
    /// truncates, else unbounded (the view clips).
    static func layoutHeight(_ shape: Shape, size: NSSize) -> CGFloat? {
        shape.isMultiline && shape.truncatesLastVisibleLine ? size.height : nil
    }

    /// The layout of `text` (font set, no paragraph settings yet) with `width` points for the
    /// text (nil: unbounded), at `scale` pixels per point.
    static func measure(_ text: NSAttributedString, font: NSFont?, shape: Shape, width: CGFloat?, scale: CGFloat) -> Metrics {
        // Alignment moves lines, not their breaks or heights: measure left-aligned, so an
        // unbounded width keeps the lines at the left edge.
        var measuring = shape
        measuring.alignment = .left
        // An empty label is one empty line of its font.
        let shown = text.length > 0 ? text
            : NSAttributedString(string: " ", attributes: [.font: font ?? .systemFont(ofSize: NSFont.systemFontSize)])
        let range = lay(paragraphed(shown, shape: measuring), shape: measuring, width: width.map { $0 + padding * 2 }, height: nil)
        guard range.length > 0 else { return Metrics(size: .zero, firstBaseline: 0, lastBaselineFromBottom: 0) }
        let used = manager.usedRect(for: container)
        let scale = max(scale, 1)
        let textWidth = text.length > 0 ? max(used.maxX - padding * 2, 0) : 0
        let size = NSSize(width: (textWidth * scale).rounded(.up) / scale, height: (used.maxY * scale).rounded(.up) / scale)
        var firstLine = NSRange(), lastLine = NSRange()
        let first = manager.lineFragmentRect(forGlyphAt: range.location, effectiveRange: &firstLine)
        let last = manager.lineFragmentRect(forGlyphAt: NSMaxRange(range) - 1, effectiveRange: &lastLine)
        let firstBaseline = first.minY + manager.location(forGlyphAt: firstLine.location).y
        let lastBaseline = last.minY + manager.location(forGlyphAt: lastLine.location).y
        return Metrics(size: size, firstBaseline: firstBaseline, lastBaselineFromBottom: size.height - lastBaseline)
    }

    /// Draws `text` (font and color set) laid out for `shape` in a top-down box of `size` (the
    /// view's bounds, padding included) at the origin of the current (flipped) graphics context
    /// `context`. As a field draws them, text of more than one line clips to the text's area (the
    /// padding stays clear) and a single line to the box.
    static func draw(_ text: NSAttributedString, shape: Shape, in size: NSSize, context: CGContext) {
        let range = lay(paragraphed(text, shape: shape), shape: shape, width: size.width, height: layoutHeight(shape, size: size))
        guard range.length > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if manager.lineFragmentRect(forGlyphAt: NSMaxRange(range) - 1, effectiveRange: nil).minY > 0 {
            context.clip(to: CGRect(x: padding, y: 0, width: max(size.width - padding * 2, 0), height: size.height))
        }
        manager.drawGlyphs(forGlyphRange: range, at: .zero)
    }

    /// The layout manager delegate that makes every line as tall as a label field's: its font's
    /// ascender and descender, each rounded up to a whole point, the baseline under the ascender
    /// (TextKit rounds the sum instead: an 11 pt line is 13 pt, a field's 14 pt).
    nonisolated final class WholePointLines: NSObject, NSLayoutManagerDelegate {
        /// How many lines it was asked about (debug.label_parity).
        var calls = 0

        func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                           lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                           in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
            calls += 1
            guard let storage = layoutManager.textStorage else { return false }
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            storage.enumerateAttribute(.font, in: characters) { value, _, _ in
                guard let font = value as? NSFont else { return }
                ascent = max(ascent, font.ascender.rounded(.up))
                descent = max(descent, (-font.descender).rounded(.up))
                leading = max(leading, font.leading.rounded(.up))
            }
            guard ascent > 0 else { return false }
            let height = ascent + descent + leading
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = ascent
            return true
        }
    }

    #if DEBUG
    /// The shared stack's line delegate calls and one line's numbers (debug.label_parity).
    static func lineReport(_ font: NSFont) -> String {
        let range = lay(NSAttributedString(string: "Hi", attributes: [.font: font]), shape: Shape(lines: 0, wraps: false, lineBreak: .byClipping,
                        alignment: .left, tightens: false, truncatesLastVisibleLine: false), width: nil, height: nil)
        let rect = range.length > 0 ? manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil) : .zero
        return "font \(font.pointSize) raw \(font.ascender - font.descender + font.leading) asc \(font.ascender) desc \(font.descender) "
            + "leading \(font.leading) default \(manager.defaultLineHeight(for: font)) line \(rect.height) used \(manager.usedRect(for: container).height) "
            + "delegate \(manager.delegate === lineHeights) calls \(lineHeights.calls)"
    }
    #endif

    /// Lays `text` out in the shared stack and returns the glyphs that fit.
    private static func lay(_ text: NSAttributedString, shape: Shape, width: CGFloat?, height: CGFloat?) -> NSRange {
        let manager = Self.manager // wires the storage, the manager and the container on first use
        configure(container, shape: shape, width: width, height: height)
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
    private static let lineHeights = LabelText.WholePointLines()

    convenience init(text: NSAttributedString, shape: LabelText.Shape, size: NSSize) {
        let storage = NSTextStorage(attributedString: LabelText.paragraphed(text, shape: shape))
        let manager = NSLayoutManager()
        manager.delegate = Self.lineHeights
        let container = NSTextContainer(size: .zero)
        LabelText.configure(container, shape: shape, width: size.width, height: LabelText.layoutHeight(shape, size: size))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        self.init(frame: NSRect(origin: .zero, size: size), textContainer: container)
        self.text = storage
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
