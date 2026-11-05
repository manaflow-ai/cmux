import AppKit
import CmuxNextDesign

/// One button of the Extensions bubble, Chrome's `HoverButton` as the legacy menu configures it
/// (`bubble_menu_item_factory.cc`): an image, an optional label with an optional second line, and
/// a rounded gray highlight that shows at once on hover. Hovering takes the keyboard focus and
/// leaving gives it up, so the pointer and the arrow keys move one highlight
/// (`ExtensionsMenuHoverButton` in `extensions_menu_item_view.cc`). A release inside, Return,
/// Space or the accessibility press runs ``onPress``. A selected button (a pinned pin) sits on
/// the theme's accent.
///
/// Laid out by frames, not constraints: the bubble's rows open and hover without an Auto Layout
/// pass (the old `NSMenu` rows solved constraints for every row on every open).
final class ExtensionsMenuHoverButton: NSView {
    /// Runs on a click, Return, Space or the accessibility press.
    var onPress: (() -> Void)?
    /// The pointer entered the button.
    var onHover: (() -> Void)?
    /// The hover, focus or press changed (a row that draws the highlight for its button).
    var onHighlightChange: (() -> Void)?
    /// False leaves the highlight to the superview (an extension row highlights as a whole).
    var drawsHighlight = true

    let imageView = ThemedImageView()
    let titleLabel = ThemedLabel(labelWithString: "")
    /// The second line under the label, when the button has one.
    let detailLabel = ThemedLabel(labelWithString: "")
    private let style: ExtensionsMenuStyle
    /// The image's box, centered on the image (28 for an extension icon, 20 for a glyph).
    private let imageBox: CGFloat
    /// Space around the image and label (the HoverButton's border).
    private let insets: NSEdgeInsets
    private let imageLabelSpacing: CGFloat

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.38
            needsDisplay = true
        }
    }

    /// Selected: the accent fill and the lit glyph (a pinned extension's pin).
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            if isSelected { imageView.themeTint = { Palette.litGlyph } } else { imageView.themeTint = tint }
            needsDisplay = true
        }
    }

    private(set) var isHovering = false { didSet { if oldValue != isHovering { highlightChanged() } } }
    private(set) var isPressed = false { didSet { if oldValue != isPressed { highlightChanged() } } }
    private(set) var hasFocus = false { didSet { if oldValue != hasFocus { highlightChanged() } } }
    /// Whether the highlight shows: hover, keyboard focus or a press.
    var isHighlighted: Bool { isEnabled && (isHovering || hasFocus || isPressed) }
    private let tint: (() -> NSColor)?
    private var tracking: NSTrackingArea?

    /// - Parameters:
    ///   - image: The icon; a template image is tinted by `tint`.
    ///   - imageSize: The icon's drawn size.
    ///   - imageBox: The box the icon is centered in.
    ///   - title: The label, or nil for an icon-only button.
    ///   - detail: Whether the label has a second line under it (``detailLabel``).
    ///   - insets: The border around the image and label.
    init(image: NSImage?, imageSize: CGFloat, imageBox: CGFloat, title: String? = nil, detail: Bool = false,
         insets: NSEdgeInsets, imageLabelSpacing: CGFloat? = nil, style: ExtensionsMenuStyle = .standard,
         tint: (() -> NSColor)? = { Palette.textSecondary }) {
        self.style = style
        self.tint = tint
        self.imageBox = imageBox
        self.insets = insets
        self.imageLabelSpacing = imageLabelSpacing ?? style.imageLabelSpacing
        super.init(frame: .zero)
        focusRingType = .none
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.themeTint = tint
        setImage(image, size: imageSize)
        addSubview(imageView)
        if let title {
            titleLabel.stringValue = title
            titleLabel.font = style.labelFont
            titleLabel.themeColor = { Palette.textPrimary }
            titleLabel.lineBreakMode = .byTruncatingTail
            addSubview(titleLabel)
        }
        if title != nil, detail {
            detailLabel.font = style.detailFont
            detailLabel.themeColor = { Palette.textSecondary }
            detailLabel.lineBreakMode = .byTruncatingTail
            addSubview(detailLabel)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if let title { setAccessibilityLabel(title) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: NSImage?, size: CGFloat) {
        imageView.image = image
        imageView.frame.size = NSSize(width: size, height: size)
        needsLayout = true
    }

    /// The width the button needs: borders, the image box, and the label when it has one.
    var preferredWidth: CGFloat {
        var width = insets.left + imageBox + insets.right
        if titleLabel.superview != nil { width += imageLabelSpacing + ceil(titleLabel.intrinsicContentSize.width) }
        return width
    }

    /// The button's height: the image box between its borders.
    var preferredHeight: CGFloat { insets.top + imageBox + insets.bottom }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = imageView.frame.size
        let boxX = insets.left
        imageView.frame.origin = NSPoint(x: boxX + (imageBox - size.width) / 2, y: (bounds.height - size.height) / 2)
        guard titleLabel.superview != nil else { return }
        // The text boxes span from `x` to the right inset; each frame adds its label's padding
        // around its text box (a frame the size of the text alone truncated the name).
        let x = boxX + imageBox + imageLabelSpacing
        let width = max(0, bounds.width - x - insets.right)
        let height = ceil(titleLabel.intrinsicContentSize.height)
        guard detailLabel.superview != nil, !detailLabel.stringValue.isEmpty else {
            titleLabel.frame = titleLabel.frame(forAlignmentRect: NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height))
            return
        }
        // Two lines centered together, the name over its access.
        let detailHeight = ceil(detailLabel.intrinsicContentSize.height)
        let top = (bounds.height - height - detailHeight) / 2
        titleLabel.frame = titleLabel.frame(forAlignmentRect: NSRect(x: x, y: top, width: width, height: height))
        detailLabel.frame = detailLabel.frame(forAlignmentRect: NSRect(x: x, y: top + height, width: width, height: detailHeight))
    }

    // MARK: Drawing

    /// The highlight: hover, keyboard focus or a press, in the theme's gray; a selected button
    /// sits on the accent, a little stronger under the pointer.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: style.highlightRadius, yRadius: style.highlightRadius)
        performWithTheme {
            if isSelected, isEnabled {
                Palette.accentFill.withAlphaComponent(isHighlighted ? style.pinnedHoverFillOpacity : style.pinnedFillOpacity).setFill()
                path.fill()
            } else if drawsHighlight, isHighlighted {
                (isPressed ? Palette.pressedFill : Palette.hoverFill).setFill()
                path.fill()
            }
        }
    }

    private func highlightChanged() {
        needsDisplay = true
        onHighlightChange?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        guard isEnabled else { return }
        // Chrome: a hovered row button takes the focus, so the keyboard continues from it.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        onHover?()
    }

    /// Reads the hover again from the pointer: a menu shown from this button tracked the mouse,
    /// so no exit event arrived while it was open.
    func refreshHover() {
        guard let window else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        isPressed = false
        isHovering = inside
        if !inside, window.firstResponder === self { window.makeFirstResponder(nil) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
        // Chrome: leaving a hovered button clears the focus it took.
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let wasPressed = isPressed
        isPressed = false
        guard isEnabled, wasPressed, inside else { return }
        onPress?()
    }

    // MARK: Keys

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        hasFocus = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Return, Enter, Space.
        guard [36, 76, 49].contains(event.keyCode), isEnabled else { return super.keyDown(with: event) }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled }
}
