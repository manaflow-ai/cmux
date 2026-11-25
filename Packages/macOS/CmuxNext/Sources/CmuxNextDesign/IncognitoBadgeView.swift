public import AppKit
import CmuxNextIcons

/// The incognito window's mark in the top row, after the toolbar band's
/// Back and Forward. With room it is a chip: the glyph and "Incognito" in
/// secondary text on the subtle hover gray, as Swift live mode's mark. Given
/// less than that width (a narrow sidebar's header) it is an icon of the
/// row: the glyph alone, centered at the toolbar buttons' size in their
/// secondary ink with no fill, in the square it is given, so it lines up with
/// the + beside it instead of showing a gray box (cmux #37351). Hovering shows
/// the tooltip in both. A press on it never moves the window. The App passes
/// its localized word and help (`WindowStrings`).
public final class IncognitoBadgeView: NSView, TitlebarPressDeciding {
    /// The chip: glyph and word, laid out by the stack (its fitting size is the badge's).
    private let chip: NSStackView
    private let chipIcon = NSImageView()
    private let label: ChromeLabel
    /// The row's icon: the glyph alone, centered.
    private let compactIcon = NSImageView()
    /// The chip's fill, resolved with the text colors (`applyColors`); the row's icon has none.
    private var chipFill: CGColor?

    /// The glyph the visible state draws (tests).
    public var glyph: NSImage? { isCompact ? compactIcon.image : chipIcon.image }

    /// Whether the word draws (tests).
    public var showsLabel: Bool { chip.alphaValue > 0 }

    /// Whether the chip's word has its whole frame (glyphs and line padding), inside the badge while the chip
    /// shows (tests). As the row's icon the faded chip may run past the square.
    public var wordFits: Bool {
        let frame = convert(label.frame, from: label.superview)
        return frame.width + 0.5 >= label.naturalSize.width && (isCompact || frame.maxX <= bounds.maxX + 0.5)
    }

    /// The gap from the chip's glyph to its word's text (the label's alignment rect), in points (tests).
    public var wordGap: CGFloat {
        let iconFrame = convert(chipIcon.frame, from: chipIcon.superview)
        let text = convert(label.alignmentRect(forFrame: label.frame), from: label.superview)
        return text.minX - iconFrame.maxX
    }

    /// Whether it draws as the row's icon: narrower than the chip.
    public var isCompact: Bool { bounds.width + 0.5 < fittingSize.width }

    /// - Parameters:
    ///   - title: The chip's word ("Incognito").
    ///   - help: The tooltip and the accessibility label.
    public init(title: String, help: String) {
        label = ChromeLabel(labelWithString: title)
        chip = NSStackView(views: [chipIcon, label])
        super.init(frame: .zero)
        wantsLayer = true
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingTail
        chipIcon.image = NSImage.icon(.browserIncognito, size: .iconRowSize(forLabelPointSize: label.font?.pointSize ?? 11))
        chip.orientation = .horizontal
        chip.spacing = Metrics.space1
        chip.edgeInsets = NSEdgeInsets(top: 2, left: Metrics.space2, bottom: 2, right: Metrics.space2)
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        // The trailing and bottom pins give way before the chip's glyph and word resist compression (750): narrower
        // than the chip, the badge is the row's icon and the faded chip keeps its own layout instead of squeezing
        // its word into the square. Above the fitting-size compression (50), so the fitting size still comes from
        // them.
        let yields = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultHigh.rawValue - 1)
        let trailing = chip.trailingAnchor.constraint(equalTo: trailingAnchor)
        let bottom = chip.bottomAnchor.constraint(equalTo: bottomAnchor)
        trailing.priority = yields
        bottom.priority = yields
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            chip.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
        compactIcon.imageScaling = .scaleNone
        compactIcon.isHidden = true
        addSubview(compactIcon)
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

    override public func layout() {
        super.layout()
        let compact = isCompact
        // Alpha, not isHidden (as the word's alpha before): the chip keeps its layout and fitting size, so it
        // returns with the room exactly as it was laid out.
        chip.alphaValue = compact ? 0 : 1
        compactIcon.isHidden = !compact
        if compact {
            let side = Metrics.smallIconSize
            if compactIcon.image?.size.height != side { compactIcon.image = NSImage.icon(.browserIncognito, size: side) }
            compactIcon.frame = NSRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(),
                                       width: side, height: side)
        }
        layer?.cornerRadius = compact ? 0 : Metrics.chipCornerRadius(height: bounds.height)
        // Only the fill follows the state here; the colors resolve at init and on an appearance change, as the
        // chip's always did (a layout-time resolve gave the word a different ink).
        layer?.backgroundColor = compact ? NSColor.clear.cgColor : chipFill
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Theme tokens only: secondary ink; the chip on the hover gray, the icon on nothing.
    public func applyColors() {
        performWithTheme {
            chipIcon.contentTintColor = Palette.textSecondary
            compactIcon.contentTintColor = Palette.textSecondary
            label.textColor = Palette.textSecondary
            chipFill = Palette.hoverFill.cgColor
        }
        layer?.backgroundColor = isCompact ? NSColor.clear.cgColor : chipFill
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}
