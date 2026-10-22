import AppKit
import CmuxNextDesign

/// A small text button in a sidebar card's corner (UPDATE-CARD-CLOSE, Lawrence 2026-10-14: "need a
/// more explicit button"): the update cards' "Hide", which says what one click does where a bare x
/// did not. Caption text in the theme's secondary color, primary with the hover fill under the
/// pointer; a button for VoiceOver (its label can say more than the text) and for Full Keyboard
/// Access (Tab, then Space or Return), with the theme's focus ring. A mouse click never takes the
/// keyboard focus: the card hides after the click, and the focus must not stay on a hidden button.
final class SidebarCardTextButton: NSView {
    var onPress: (() -> Void)?
    private let label = ChromeLabel(labelWithString: "")
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    private lazy var keyRepaint = KeyWindowRepaint(self)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .none
        layer?.cornerCurve = .continuous
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        // VoiceOver reads the button, not its text twice.
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static var font: NSFont { Typography.system(size: Typography.caption.pointSize, weight: .medium) }
    static var height: CGFloat { ceil(font.boundingRectForFont.height) + Metrics.space1 }

    /// `title` drawn and `help` as the tooltip; VoiceOver reads `help` as the label (nil: the title).
    func configure(title: String, help: String?) {
        label.stringValue = title
        themedToolTip = help
        setAccessibilityLabel(help ?? title)
        setAccessibilityHelp(nil)
        needsLayout = true
        needsDisplay = true
    }

    /// The drawn text.
    var title: String { label.stringValue }

    /// The width the text needs, with the hover fill's inset on both sides.
    var fittingWidth: CGFloat {
        label.font = Self.font
        return ceil(label.naturalSize.width) + 2 * Metrics.space1
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Metrics.space1
        label.font = Self.font
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Metrics.space1, y: (bounds.height - h) / 2, width: max(0, bounds.width - 2 * Metrics.space1), height: h)
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = (isPressed ? Palette.pressedFill : isHovered ? Palette.hoverFill : .clear).cgColor
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = KeyWindowRepaint.showsFocus(self, focused: isKeyFocused) ? Metrics.lineWidth(1.5) : 0
            label.textColor = isHovered || isPressed ? Palette.textPrimary : Palette.textSecondary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    /// Acts on release inside, like a button.
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        isPressed = false
    }

    /// A press (click, Space, Return, VoiceOver). The card hides after it: a keyboard focus here
    /// moves on first, so it never stays on a hidden button.
    func press() {
        if window?.firstResponder === self { window?.selectNextKeyView(nil) }
        onPress?()
    }

    /// A right click on the button shows its card's menu (remind me later), the first one up the
    /// view tree.
    override func menu(for event: NSEvent) -> NSMenu? {
        var view = superview
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override var acceptsFirstResponder: Bool {
        guard NSApp.isFullKeyboardAccessEnabled else { return false }
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        return !(NSApp.currentEvent.map { mouse.contains($0.type) } ?? false)
    }

    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyRepaint.track()
    }

    override func becomeFirstResponder() -> Bool {
        isKeyFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyFocused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard SidebarUpdateToggle.isActivationKey(event) else { return super.keyDown(with: event) }
        press()
    }
}
