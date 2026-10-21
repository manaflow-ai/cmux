public import AppKit

/// The specular rim of a ``FloatingGlassStyle`` surface: a 1 px inside stroke that fades from a
/// bright top edge to a faint bottom one, drawn above the material and the content. It takes no
/// clicks.
@MainActor
public final class GlassRimView: NSView {
    private let gradient = CAGradientLayer()
    private let stroke = CAShapeLayer()

    /// The continuous corner radius of the surface it outlines.
    public var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    /// The rim's colors.
    public var look: FloatingGlassLook {
        didSet { if look != oldValue { applyColors() } }
    }

    /// - Parameters:
    ///   - cornerRadius: The surface's corner radius.
    ///   - look: The rim colors for the current appearance.
    public init(cornerRadius: CGFloat, look: FloatingGlassLook) {
        self.cornerRadius = cornerRadius
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.black.cgColor
        gradient.mask = stroke
        setAccessibilityElement(false)
        applyColors()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let width = 1 / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        stroke.frame = bounds
        stroke.lineWidth = width
        let inset = bounds.insetBy(dx: width / 2, dy: width / 2)
        // CoreGraphics refuses a corner wider than half the rect.
        let radius = min(max(cornerRadius - width / 2, 0), max(min(inset.width, inset.height) / 2, 0))
        stroke.path = inset.width > 0 && inset.height > 0
            ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        CATransaction.commit()
    }

    private func applyColors() {
        gradient.colors = [look.rimTop.nsColor.cgColor, look.rimBottom.nsColor.cgColor]
    }
}
