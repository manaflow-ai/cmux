import AppKit
import CmuxNextDesign

/// A button of Meet Chief's card: the accent-filled primary (Continue, Start chatting), a quiet text button
/// (Skip, Back, Open Settings), or one segment of a picker (a density, the text size's minus and plus), raised
/// while it is the one picked. Drawn as a layer, not a bezel NSButton, which turns gray when the window is not
/// key and reads as disabled. It lights under the pointer, darkens while pressed, and runs `onClick` on a click
/// released inside it, on VoiceOver's press, and on Return while it has keyboard focus (Home sends Space, like
/// every printable key, to the message box first).
final class HomeChiefOnboardingButton: NSView {
    enum Style { case primary, quiet, segment }

    let style: Style
    let label = ChromeLabel(labelWithString: "")
    var onClick: () -> Void = {}
    /// A segment that is the one picked: raised on the card's fill with a hairline.
    var isOn = false { didSet { if isOn != oldValue { applyFont(); paint(); setAccessibilityValue(isOn) } } }
    /// Off: dimmed, and clicks do nothing (the text size at the end of its range).
    var isEnabled = true { didSet { if isEnabled != oldValue { alphaValue = isEnabled ? 1 : 0.4; setAccessibilityEnabled(isEnabled) } } }
    var title: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    static let height: CGFloat = 28
    private var scale: CGFloat = 1
    private var fill = NSColor.clear
    private var hoverFill = NSColor.clear
    private var pressedFill = NSColor.clear
    private var onFill = NSColor.clear
    private var onText = NSColor.labelColor
    private var offText = NSColor.secondaryLabelColor
    private var border = NSColor.clear
    private var isHovered = false { didSet { if isHovered != oldValue { paint() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { paint() } } }

    init(style: Style, title: String) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.isSelectable = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        self.title = title
        applyScale(1)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// The button's width: its title with room either side.
    var fittingWidth: CGFloat { ceil(label.attributedStringValue.size().width) + 2 * (style == .primary ? 14 : 8) * scale }

    func applyScale(_ scale: CGFloat) {
        self.scale = scale
        applyFont()
        // A segment sits 2 points inside its track, which rounds as a button: concentric with it.
        layer?.cornerRadius = style == .segment ? Metrics.buttonCornerRadius(inset: 2 * scale) : Metrics.buttonCornerRadius
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyFont() {
        let size = (style == .primary ? TypeScale.Base.body : TypeScale.Base.detail) * scale
        let emphasis = style == .primary || (style == .segment && isOn)
        label.font = .systemFont(ofSize: size, weight: emphasis ? TypeScale.emphasis : .regular)
    }

    /// Colours from the theme (caller runs inside `performWithTheme`): the primary takes the accent and its text;
    /// a quiet button its text colour and the hover fill only under the pointer.
    func applyColors(text: NSColor, accent: NSColor, onAccent: NSColor, hover: NSColor) { // theme-scoped
        switch style {
        case .primary:
            label.textColor = onAccent
            fill = accent
            hoverFill = accent.blended(withFraction: 0.08, of: .white) ?? accent
            pressedFill = accent.blended(withFraction: 0.15, of: .black) ?? accent
        case .quiet, .segment:
            label.textColor = text
            fill = .clear
            hoverFill = hover
            pressedFill = hover.withAlphaComponent(min(1, hover.alphaComponent * 1.8))
        }
        paint()
    }

    /// A segment's colours (caller runs inside `performWithTheme`): `on` is the raised fill of the picked one.
    func applySegmentColors(on: NSColor, onText: NSColor, offText: NSColor, border: NSColor, hover: NSColor) { // theme-scoped
        onFill = on
        self.onText = onText
        self.offText = offText
        self.border = border
        hoverFill = hover
        pressedFill = hover.withAlphaComponent(min(1, hover.alphaComponent * 1.8))
        paint()
    }

    private func paint() {
        if style == .segment {
            label.textColor = isOn ? onText : offText
            layer?.borderWidth = isOn ? 1 : 0
            layer?.borderColor = border.cgColor
            let color = isOn ? onFill : isPressed && isEnabled ? pressedFill : isHovered && isEnabled ? hoverFill : .clear
            layer?.backgroundColor = color.cgColor
            return
        }
        let color = isPressed ? pressedFill : isHovered ? hoverFill : fill
        layer?.backgroundColor = color.cgColor
    }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: Self.height * scale) }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseDragged(with event: NSEvent) { isPressed = bounds.contains(convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        // On release, inside: dragging away cancels the click.
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = Metrics.controlCornerRadius * scale
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: if !event.isARepeat { onClick() } // Return, keypad Enter
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick()
        return true
    }
}
