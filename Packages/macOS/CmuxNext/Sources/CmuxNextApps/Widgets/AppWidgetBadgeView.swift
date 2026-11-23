import AppKit
import CmuxNextDesign

/// Edit mode's minus badge on a widget tile (Apple's remove badge): a small round button. Held, it
/// changes only its fill (design/pressed-state.md); the glyph stays.
final class AppWidgetBadgeView: NSView {
    /// The badge's side.
    static let side: CGFloat = 18
    var onPress: (() -> Void)?
    private let disc = CALayer()
    private let bar = CALayer()
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for sublayer in [disc, bar] {
            sublayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(sublayer)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(AppWidgetStrings.remove)
        themedToolTip = AppWidgetStrings.remove
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = bounds
        disc.cornerRadius = bounds.height / 2
        let width = floor(bounds.width * 0.5), height: CGFloat = 2
        bar.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        bar.cornerRadius = height / 2
        CATransaction.commit()
    }

    override func updateLayer() {
        performWithTheme {
            disc.backgroundColor = (isPressed ? Palette.pressedFill : Palette.badgeFill).cgColor
            disc.borderColor = Palette.separator.cgColor
            disc.borderWidth = Metrics.dividerThickness
            bar.backgroundColor = Palette.textPrimary.cgColor
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fire = isPressed
        isPressed = false
        if fire { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
