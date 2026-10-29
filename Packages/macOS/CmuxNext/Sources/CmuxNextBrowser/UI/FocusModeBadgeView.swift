import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The badge at the trailing end of the omnibar while the page is in browser
/// focus mode (classic cmux's toolbar mode chip): a keyboard glyph and "Focus
/// Mode", or "Esc again to exit" once the first Escape armed the exit.
/// Clicking it leaves focus mode.
final class FocusModeBadgeView: NSView {
    private let label = ChromeLabel(labelWithString: "")
    private let glyph = NSImageView()
    /// Runs on click: the host leaves focus mode.
    var onPress: (() -> Void)?
    /// The text shown now (tests).
    var shownText: String { label.stringValue }
    /// The label's color now (tests).
    var shownTextColor: NSColor? { label.textColor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        label.font = Typography.caption
        // The chip keeps its text's width beside the URL field (250), as the machine chip does.
        setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        // chrome-icons: allow Chrome has no focus mode; classic cmux's chip used the keyboard glyph.
        glyph.image = NSImage.icon(.keyboard, size: 12)
        glyph.image?.isTemplate = true
        addSubview(glyph)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("cmux.browser.focusModeBadge")
        show(armed: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The badge takes the whole press (not its image or label) and the first
    /// one in a browser window that is not key: one click acts, as Chrome's
    /// omnibar buttons do (user, 2026-10-28, "click the star twice").
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Whether the exit is armed in the text shown now; nil before the first show.
    private var armed: Bool?

    func show(armed: Bool) {
        guard armed != self.armed else { return }
        let first = self.armed == nil
        self.armed = armed
        label.stringValue = armed ? Strings.focusModeArmed : Strings.focusModeActive
        invalidateIntrinsicContentSize()
        needsLayout = true // invalidate: the other text (the guard above) at another width
        let help = Strings.focusModeExitHelp(Strings.focusModeEscapeHint)
        themedToolTip = help
        setAccessibilityLabel(label.stringValue)
        setAccessibilityHelp(help)
        // The chip's colors do not follow its text (the label repaints itself): the first show
        // paints them at once, a theme change repaints them through `updateLayer`.
        if first { updateLayer() }
    }

    // MARK: Frame layout

    /// The glyph 6 pt from the leading edge, the text 4 pt after it and 6 pt from the trailing edge,
    /// both centered on an 18 pt chip.
    var chipLayout: ChipLayout {
        ChipLayout(items: [ChipLayout.Item(glyph.intrinsicContentSize), ChipLayout.Item(label.intrinsicContentSize, flexible: true)],
                   spacing: 4, insets: ChipLayout.Insets(horizontal: 6, vertical: 0), minHeight: 18)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: chipLayout.preferredSize.width, height: 18) }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true } // invalidate: a new size (the check above) re-frames the glyph and text
    }

    override func layout() {
        super.layout()
        let frames = chipLayout.frames(in: bounds.size, rightToLeft: userInterfaceLayoutDirection == .rightToLeft)
        guard frames.count == 2 else { return }
        glyph.setAlignmentFrame(frames[0])
        label.setAlignmentFrame(frames[1])
    }

    override func mouseDown(with event: NSEvent) { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // A lit chip in the theme's accent, never orange (Leo 2026-10-21: "the accent is never orange").
        performWithTheme {
            layer?.backgroundColor = Palette.accentFill.withAlphaComponent(0.16).cgColor
            label.textColor = Palette.litGlyph
            glyph.contentTintColor = Palette.litGlyph
        }
    }
}
