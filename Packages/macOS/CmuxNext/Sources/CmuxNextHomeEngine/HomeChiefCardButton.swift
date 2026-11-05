import AppKit
import CmuxNextDesign

/// A round button of a Chief card (the chat's computer popup): its fill follows hover and press, and the
/// keyboard's focus ring follows its shape.
@MainActor
class HomeChiefCardButton: NSButton {
    private(set) var isHovering = false
    private(set) var isPressed = false
    private var tracking: NSTrackingArea?

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Draws the button's state, in its theme.
    func applyTheme() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyTheme()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTheme()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = layer?.cornerRadius ?? 0
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// A Chief card's round close button.
@MainActor
final class HomeChiefCardCloseButton: HomeChiefCardButton {
    init(label: String, target: AnyObject, action: Selector, size: CGFloat = 36, symbolSize: CGFloat = 15) {
        super.init(cornerRadius: size / 2)
        self.target = target
        self.action = action
        title = ""
        imagePosition = .imageOnly
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: label)
        setAccessibilityLabel(label)
        themedToolTip = label
        layer?.borderWidth = 1
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        applyTheme()
    }

    override func applyTheme() {
        performWithTheme {
            layer?.backgroundColor = (isHovering || isPressed ? Palette.pressedFill : Palette.hoverFill).cgColor
            layer?.borderColor = Palette.paneBorder.cgColor
            contentTintColor = Palette.textPrimary
        }
    }
}
