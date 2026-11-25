public import AppKit
public import QuartzCore

/// A native edge's rim light under wallpaper lighting (``WallpaperLight``): the key light's color
/// along a rounded outline (a pane's content edge, the sidebar's edge), brightest where it faces
/// the light and fading away from it. A radial gradient centered on the light, masked to the
/// outline's stroke; both are set once per light change or host layout, never per frame. Hidden
/// while the setting is off, without a field, or where the light is too weak to show.
///
/// ```swift
/// let rim = WallpaperRimLayer(host: self)
/// layer?.addSublayer(rim)
/// rim.place(contentRect, cornerRadius: 10, lineWidth: 1)
/// ```
/// Nonisolated, as Core Animation makes its presentation copy (`init(layer:)`) off the main actor; what
/// reads the host or the light is main-actor.
nonisolated public final class WallpaperRimLayer: CAGradientLayer {
    private weak var host: NSView?
    /// Nil only in a presentation copy of a layer that had none.
    private let light: WallpaperLight?
    private let stroke = CAShapeLayer()
    private var shape: (rect: CGRect, radius: CGFloat, width: CGFloat)?

    /// A rim drawn in `host`'s coordinates (its layer's sublayer), lit by `light` (the app's by default).
    @MainActor
    public init(host: NSView, light: WallpaperLight = BackdropImageStore.shared.light) {
        self.host = host
        self.light = light
        super.init()
        type = .radial
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.black.cgColor
        mask = stroke
        isHidden = true
        light.register(self)
    }

    /// Core Animation's copy for the presentation layer.
    override public init(layer: Any) {
        light = (layer as? WallpaperRimLayer)?.light
        super.init(layer: layer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// The host hides its content frame (a chat on the window glass): no rim.
    @MainActor public var suppressed = false {
        didSet { if suppressed != oldValue { apply() } }
    }

    /// Traces `rect` (the host's coordinates) with `cornerRadius`, `lineWidth` points wide. A host may call it
    /// on every layout pass: an unchanged shape, or any shape while lighting is off, costs a comparison.
    @MainActor
    public func place(_ rect: CGRect, cornerRadius: CGFloat, lineWidth: CGFloat) {
        let next = (rect, cornerRadius, lineWidth)
        if let shape, shape == next { return }
        shape = next
        guard light?.enabled == true || !isHidden else { return }
        apply()
    }

    /// The light or the host's place on screen changed.
    @MainActor func lightDidChange() { apply() }

    @MainActor
    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !suppressed, let host, let window = host.window, let shape, shape.rect.width > 0, shape.rect.height > 0,
              let light, let lit = light.field(for: window)
        else {
            isHidden = true
            return
        }
        let onScreen = window.convertToScreen(host.convert(shape.rect, to: nil))
        guard let rim = lit.field.rim(rect: onScreen, container: lit.screen ?? window.frame), rim.alpha > 0.02 else {
            isHidden = true
            return
        }
        frame = shape.rect
        let inset = shape.width / 2
        let radius = max(0, min(shape.radius - inset, min(bounds.width, bounds.height) / 2 - inset))
        stroke.frame = bounds
        stroke.lineWidth = shape.width
        stroke.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: radius, cornerHeight: radius, transform: nil)
        let color = lit.field.rim
        colors = [NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: rim.alpha).cgColor, // colour-allow: the wallpaper's key light, read per picture
                  NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 0).cgColor] // colour-allow: the same light, faded out
        // The field's unit space grows down from the top left; an unflipped host's layer grows up.
        let y = { (v: CGFloat) in host.isFlipped ? v : 1 - v }
        startPoint = CGPoint(x: rim.center.x, y: y(rim.center.y))
        endPoint = CGPoint(x: rim.center.x + rim.radius.width, y: y(rim.center.y) + (host.isFlipped ? 1 : -1) * rim.radius.height)
        isHidden = false
    }
}
