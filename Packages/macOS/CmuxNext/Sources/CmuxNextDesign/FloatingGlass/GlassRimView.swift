public import AppKit

/// The specular rim of a ``FloatingGlassStyle`` surface: a 1 px inside stroke that fades from a
/// bright top edge to a faint bottom one, drawn above the material and the content. It takes no
/// clicks.
@MainActor
public final class GlassRimView: NSView {
    let gradient = CAGradientLayer()
    private let stroke = CAShapeLayer()

    /// The continuous corner radius of the surface it outlines.
    public var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    /// The rim's colors.
    public var look: FloatingGlassLook {
        didSet { if look != oldValue { applyColors() } }
    }

    /// When set, the rim fades out this far below the surface's top edge, so a tall surface (a sidebar group's block)
    /// keeps its lit top and corners and draws no hairline down its sides. Nil fades top to bottom over the whole height.
    public var fadeDepth: CGFloat? {
        didSet { if fadeDepth != oldValue { applyColors(); needsLayout = true } }
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
        // A hairline like any other: none under `appearance.borders` none (the Blocks window style).
        stroke.lineWidth = Borders.width(width)
        let inset = bounds.insetBy(dx: width / 2, dy: width / 2)
        // CoreGraphics refuses a corner wider than half the rect.
        let radius = min(max(cornerRadius - width / 2, 0), max(min(inset.width, inset.height) / 2, 0))
        stroke.path = inset.width > 0 && inset.height > 0
            ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        gradient.locations = fadeDepth.map { [0, NSNumber(value: Double(min(1, $0 / max(bounds.height, 1))))] }
        CATransaction.commit()
    }

    private func applyColors() {
        let bottom = fadeDepth == nil ? look.rimBottom : FloatingGlassLook.Gray(white: look.rimTop.white, alpha: 0)
        gradient.colors = [look.rimTop.nsColor.cgColor, bottom.nsColor.cgColor]
    }
}
