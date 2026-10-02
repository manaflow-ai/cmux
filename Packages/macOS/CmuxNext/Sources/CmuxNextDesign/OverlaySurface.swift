public import AppKit

/// An overlay surface drawn in an `OverlayMaterial`, with one shape (a
/// continuous rounded rect of `cornerRadius`) whatever the material, so the
/// overlay's frame, corners and motion are the same on every path. It
/// follows Reduce Transparency live (`ReduceTransparency`) and re-reads
/// theme colors whenever its effective appearance or theme scope changes.
/// Content goes in `contentView`, above the material, and may size the
/// surface through constraints. Every floating glass panel (palette, hover
/// card, find and prompt bars, drop overlay) is one of these, made with
/// `Glass.makeOverlayPanel`; raw `Glass.makePanel` has no fallback.
@MainActor
public final class OverlaySurfaceView: NSView {
    public private(set) var material: OverlayMaterial
    public let contentView = NSView()
    /// Panels take clicks and hovers; a pure overlay (the drop target, a
    /// HUD) lets them through to the views beneath.
    public let isInteractive: Bool
    private var materialView: NSView?
    private var tintView: NSView?
    /// Pins one material (tests, `debug.drop_highlight`); nil follows this Mac.
    public var materialOverride: OverlayMaterial? {
        didSet { refreshMaterial() }
    }

    public var cornerRadius: CGFloat = Metrics.panelCornerRadius {
        didSet { if cornerRadius != oldValue { applyShape() } }
    }

    /// `material` pins one material (tests, previews); nil follows this Mac.
    public init(material: OverlayMaterial? = nil, interactive: Bool = false,
                cornerRadius: CGFloat = Metrics.panelCornerRadius) {
        materialOverride = material
        isInteractive = interactive
        self.cornerRadius = cornerRadius
        self.material = material ?? OverlayMaterial.current
        super.init(frame: .zero)
        wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = [.width, .height]
        rebuild()
        ReduceTransparency.register(self)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that draws the material (an `NSGlassEffectView`,
    /// `NSVisualEffectView` or a plain layer-backed view).
    public var materialDrawingView: NSView? { materialView }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    /// Re-reads the material from this Mac's settings (Reduce Transparency).
    public func refreshMaterial() {
        let next = materialOverride ?? OverlayMaterial.current
        guard next != material else { return }
        material = next
        rebuild()
    }

    private func rebuild() {
        materialView?.removeFromSuperview()
        contentView.removeFromSuperview()
        tintView = nil
        let view: NSView
        switch material {
        case .liquidGlass:
            let glass = Glass.makePanel(content: contentView, style: .regular, cornerRadius: cornerRadius)
            glass.translatesAutoresizingMaskIntoConstraints = true
            view = glass
        case .vibrancy:
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            // The Ghostty-derived tint sits on the blur, under the content.
            let tint = NSView(frame: effect.bounds)
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            tint.addSubview(contentView)
            effect.addSubview(tint)
            tintView = tint
            view = effect
        case .opaque:
            let plain = NSView()
            plain.wantsLayer = true
            plain.addSubview(contentView)
            view = plain
        }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        // NSGlassEffectView lays its contentView out with constraints; out
        // of the glass it must size by its frame again.
        if material != .liquidGlass {
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentView.autoresizingMask = [.width, .height]
            tintView?.frame = view.bounds
            contentView.frame = view.bounds
        }
        addSubview(view)
        materialView = view
        applyShape()
        applyTheme()
        // Content colors may depend on the material (a veil that only
        // glass needs): the content re-resolves them like on a theme change.
        ThemeScope.invalidate(contentView)
    }

    private func applyShape() {
        if let glass = materialView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else if let layer = materialView?.layer {
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderWidth = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
        }
    }

    /// Theme colors: the glass tint, or the fallback's Ghostty-derived fill
    /// and hairline. Never an accent color.
    public func applyTheme() {
        performWithTheme {
            switch material {
            case .liquidGlass:
                (materialView as? NSGlassEffectView)?.tintColor = overlayTint
            case .vibrancy:
                tintView?.layer?.backgroundColor = overlayTint.cgColor
                materialView?.layer?.borderColor = Palette.separator.cgColor
            case .opaque:
                let fill = themeTokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)
                materialView?.layer?.backgroundColor = fill.cgColor
                materialView?.layer?.borderColor = Borders.color(Palette.separator.withAlphaComponent(1)).cgColor
            }
        }
        applyShape()
    }

    /// The theme's glass tint, its alpha scaled by the overlay tint
    /// strength tunable (1, the default, is the theme tint unchanged).
    private var overlayTint: NSColor {
        let tint = Palette.glassTint
        let strength = ChromeTunables.glassOverlayTintStrength.value
        guard strength != 1 else { return tint }
        return tint.withAlphaComponent(min(max(tint.alphaComponent * strength, 0), 1))
    }
}

extension NSView {
    /// The material of the overlay surface this view sits in, or nil
    /// outside one. Content that only glass needs (a legibility veil)
    /// checks it in its color hook, which reruns when the material changes.
    public var enclosingOverlayMaterial: OverlayMaterial? {
        var current = superview
        while let view = current {
            if let surface = view as? OverlaySurfaceView { return surface.material }
            current = view.superview
        }
        return nil
    }
}
