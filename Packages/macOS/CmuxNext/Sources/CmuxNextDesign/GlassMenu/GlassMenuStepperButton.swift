import AppKit

/// One button of a ``GlassMenuStepperRowView``: a symbol on the menu glass with the row highlight's
/// fill under the pointer and a press fill, inked like the menu's text (tertiary when disabled). A
/// release inside it, or the accessibility press, calls ``onPress``; the menu stays open.
@MainActor
final class GlassMenuStepperButton: NSView {
    /// The button's side (points): a menu row's height less the highlight's inset above and below.
    static let side: CGFloat = 22

    var onPress: (() -> Void)?
    var isEnabled = true {
        didSet {
            glyph.ink = isEnabled ? .primary : .tertiary
            needsDisplay = true
        }
    }

    private let glyph = ThemedImageView()
    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    private var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    /// A button showing the SF Symbol `symbol`, labelled `label` for VoiceOver and its tooltip.
    init(symbol: String, label: String, toolTip: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        glyph.image = NSImage.menuSymbol(symbol)
        glyph.imageScaling = .scaleProportionallyDown
        glyph.ink = .primary
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor), glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: MenuMetrics.iconSize),
            glyph.heightAnchor.constraint(equalToConstant: MenuMetrics.iconSize),
        ])
        self.toolTip = toolTip ?? label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled, isHovering || isPressed else { return }
        let radius = PopupStyle.standard.rowCornerRadius
        performWithTheme {
            (isPressed ? Palette.pressedFill : Palette.hoverFill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isPressed = isEnabled }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { press() }
    }

    override func accessibilityPerformPress() -> Bool { press() }

    /// Runs ``onPress`` when enabled; returns whether it did.
    @discardableResult
    func press() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}
