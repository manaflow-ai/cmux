public import AppKit

/// ``OverlaySurfaceView/edgeView``: a one-device-pixel inside stroke of the theme's edge color along the
/// surface's continuous rounded rect, above the material and the content. It takes no clicks.
@MainActor
public final class ThemeEdgeView: NSView {
    private let stroke = CAShapeLayer()

    /// The continuous corner radius of the surface it outlines.
    public var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    /// The edge's color: the theme's (``OverlaySurfaceView/themeEdge(_:)``), clear under `appearance.borders` none.
    public var color: NSColor = .clear {
        didSet { stroke.strokeColor = Borders.color(color).cgColor }
    }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.strokeColor = nil
        layer?.addSublayer(stroke)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let width = 1 / max(window?.backingScaleFactor ?? 2, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.frame = bounds
        stroke.lineWidth = Borders.width(width)
        let inset = bounds.insetBy(dx: width / 2, dy: width / 2)
        let radius = min(max(cornerRadius - width / 2, 0), max(min(inset.width, inset.height) / 2, 0))
        stroke.path = inset.width > 0 && inset.height > 0
            ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        CATransaction.commit()
    }
}
