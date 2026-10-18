import AppKit

/// The text layout of ``ChromeLabel`` (cx-8w027.26): one TextKit stack, shared by every label on
/// the main thread, lays a label's text out for its size, its baselines and its glyphs.
///
/// It lays out as a label field's cell does: a line fragment padding of 2 pt on each side, the
/// first line at the top edge, soft wrapping only for a wrapping label (``Shape/isMultiline``),
/// the line count limit of the text container, and the line break mode on the last line.
enum LabelText {
    /// The settings that shape the lines (not the color).
    struct Shape: Equatable {
        var lines: Int
        var wraps: Bool
        var lineBreak: NSLineBreakMode
        var alignment: NSTextAlignment
        var tightens: Bool
        var truncatesLastVisibleLine: Bool

        /// The text wraps at the width: a wrapping label, or more than one line allowed.
        var isMultiline: Bool { lines != 1 && (lines > 1 || wraps) }
    }

    /// A laid-out text: its size (whole points, up) and baselines.
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
    private static let manager: NSLayoutManager = {
        let manager = NSLayoutManager()
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
        let lineBreak: NSLineBreakMode = shape.isMultiline ? (shape.lineBreak == .byCharWrapping ? .byCharWrapping : .byWordWrapping) : shape.lineBreak
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

    /// Sets `container` up for `shape` at `size` (nil width: unbounded, one line per paragraph).
    static func configure(_ container: NSTextContainer, shape: Shape, width: CGFloat?, height: CGFloat?) {
        container.lineFragmentPadding = padding
        container.maximumNumberOfLines = max(shape.lines, 0)
        container.lineBreakMode = shape.lineBreak
        let size = NSSize(width: width ?? .greatestFiniteMagnitude, height: height ?? .greatestFiniteMagnitude)
        if container.size != size { container.size = size }
    }

    /// The height a drawing at `size` lays out in: the frame for a label whose last visible line
    /// truncates, else unbounded (the view clips).
    static func layoutHeight(_ shape: Shape, size: NSSize) -> CGFloat? {
        shape.isMultiline && shape.truncatesLastVisibleLine ? size.height : nil
    }

    /// The layout of `text` (font set, no paragraph settings yet) at `width`.
    static func measure(_ text: NSAttributedString, font: NSFont?, shape: Shape, width: CGFloat?) -> Metrics {
        // Alignment moves lines, not their breaks or heights: measure left-aligned, so an
        // unbounded width keeps the lines at the left edge.
        var measuring = shape
        measuring.alignment = .left
        let range = lay(paragraphed(text, shape: measuring), shape: measuring, width: width, height: nil)
        guard range.length > 0 else {
            let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let height = manager.defaultLineHeight(for: font)
            return Metrics(size: NSSize(width: padding * 2, height: height.rounded(.up)),
                           firstBaseline: manager.defaultBaselineOffset(for: font),
                           lastBaselineFromBottom: height.rounded(.up) - manager.defaultBaselineOffset(for: font))
        }
        let used = manager.usedRect(for: container)
        let size = NSSize(width: used.maxX.rounded(.up), height: used.maxY.rounded(.up))
        var firstLine = NSRange(), lastLine = NSRange()
        let first = manager.lineFragmentRect(forGlyphAt: range.location, effectiveRange: &firstLine)
        let last = manager.lineFragmentRect(forGlyphAt: NSMaxRange(range) - 1, effectiveRange: &lastLine)
        let firstBaseline = first.minY + manager.location(forGlyphAt: firstLine.location).y
        let lastBaseline = last.minY + manager.location(forGlyphAt: lastLine.location).y
        return Metrics(size: size, firstBaseline: firstBaseline, lastBaselineFromBottom: size.height - lastBaseline)
    }

    /// Draws `text` (font and color set) laid out for `shape` in a top-down box of `size` at
    /// the origin of the current (flipped) graphics context.
    static func draw(_ text: NSAttributedString, shape: Shape, in size: NSSize) {
        let range = lay(paragraphed(text, shape: shape), shape: shape, width: size.width, height: layoutHeight(shape, size: size))
        guard range.length > 0 else { return }
        manager.drawGlyphs(forGlyphRange: range, at: .zero)
    }

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

    convenience init(text: NSAttributedString, shape: LabelText.Shape, size: NSSize) {
        let storage = NSTextStorage(attributedString: LabelText.paragraphed(text, shape: shape))
        let manager = NSLayoutManager()
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
