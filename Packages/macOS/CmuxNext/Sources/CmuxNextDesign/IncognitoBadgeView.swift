public import AppKit
import CmuxNextIcons

/// The incognito window's mark in the top row, after the toolbar band's
/// Back and Forward. With room it is a chip: the glyph and "Incognito" in
/// secondary text on the subtle hover gray, as Swift live mode's mark. Given
/// less than that width (a narrow sidebar's header) it is an icon of the
/// row: a square as tall as it is given, the glyph centered at the toolbar
/// buttons' size in their secondary ink, with no fill, so it lines up with
/// the + beside it instead of showing a stretched gray pill (cmux #37351).
/// Hovering shows the tooltip in both. A press on it never moves the window.
/// The App passes its localized word and help (`WindowStrings`).
public final class IncognitoBadgeView: NSView, TitlebarPressDeciding {
    private let icon = NSImageView()
    private let label: ChromeLabel
    /// The glyph's point size the image was drawn at (0: not yet drawn).
    private var renderedGlyphSize: CGFloat = 0

    /// The glyph drawn (tests).
    public var glyph: NSImage? { icon.image }

    /// Whether the label draws (tests).
    public var showsLabel: Bool { !isCompact }

    /// Whether it draws as the row's icon: narrower than the chip.
    public var isCompact: Bool { bounds.width + 0.5 < chipSize.width }

    /// - Parameters:
    ///   - title: The chip's word ("Incognito").
    ///   - help: The tooltip and the accessibility label.
    public init(title: String, help: String) {
        label = ChromeLabel(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        label.font = Typography.caption
        label.lineBreakMode = .byClipping
        icon.imageScaling = .scaleNone
        addSubview(icon)
        addSubview(label)
        themedToolTip = help
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(help)
        setAccessibilityIdentifier("window.incognito.badge")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .staysPut }

    // MARK: Size

    private static let verticalPadding: CGFloat = 2

    /// The chip's glyph size: beside caption text (read live, density changes apply).
    private var chipGlyphSize: CGFloat { .iconRowSize(forLabelPointSize: label.font?.pointSize ?? 11) }

    /// The chip's size, glyph and word: what the row gives it when it has room.
    public var chipSize: NSSize {
        let text = label.intrinsicContentSize
        let glyph = chipGlyphSize
        let height = ceil(max(text.height, glyph) + Self.verticalPadding * 2)
        let width = ceil(Metrics.space2 + glyph + Metrics.space1 + text.width + Metrics.space2)
        return NSSize(width: width, height: height)
    }

    override public var fittingSize: NSSize { chipSize }
    override public var intrinsicContentSize: NSSize { chipSize }

    // MARK: Layout

    override public func layout() {
        super.layout()
        let compact = isCompact
        let glyphSize = compact ? Metrics.smallIconSize : chipGlyphSize
        renderGlyph(size: glyphSize)
        // Alpha, not isHidden: the label keeps its size, so the word returns with the room.
        label.alphaValue = compact ? 0 : 1
        if compact {
            icon.frame = NSRect(x: ((bounds.width - glyphSize) / 2).rounded(), y: ((bounds.height - glyphSize) / 2).rounded(),
                                width: glyphSize, height: glyphSize)
            layer?.cornerRadius = 0
        } else {
            icon.frame = NSRect(x: Metrics.space2, y: ((bounds.height - glyphSize) / 2).rounded(), width: glyphSize, height: glyphSize)
            let text = label.intrinsicContentSize
            label.frame = NSRect(x: icon.frame.maxX + Metrics.space1, y: ((bounds.height - text.height) / 2).rounded(),
                                 width: max(0, bounds.width - icon.frame.maxX - Metrics.space1 - Metrics.space2), height: text.height)
            layer?.cornerRadius = Metrics.chipCornerRadius(height: bounds.height)
        }
        applyColors()
    }

    private func renderGlyph(size: CGFloat) {
        guard size != renderedGlyphSize else { return }
        renderedGlyphSize = size
        icon.image = NSImage.icon(.browserIncognito, size: size)
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: Colors

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Theme tokens only: secondary ink; the chip on the hover gray, the icon on nothing.
    public func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textSecondary
            label.textColor = Palette.textSecondary
            layer?.backgroundColor = isCompact ? NSColor.clear.cgColor : Palette.hoverFill.cgColor
        }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}
