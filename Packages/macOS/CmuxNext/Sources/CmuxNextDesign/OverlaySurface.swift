public import AppKit

/// An overlay surface drawn in an `OverlayMaterial`, with one shape (a
/// continuous rounded rect of `cornerRadius`) whatever the material, so the
/// overlay's frame, corners and motion are the same on every path. It
/// follows Reduce Transparency live (`ReduceTransparency`) and re-reads
/// theme colors whenever its effective appearance or theme scope changes.
/// Content goes in `contentView`, above the material, and may size the
/// surface through constraints. Every floating panel that carries text
/// (palette, dialogs, hover cards, find and prompt bars, page info,
/// popovers) is one of these, made with `Glass.makeOverlayPanel`, and
/// follows this Mac's material like the overlays without text (the drop
/// overlay, dock backdrop): themed Liquid Glass, whose tint
/// (`glassOverlayTintStrength`) keeps its text over busy content.
@MainActor
public final class OverlaySurfaceView: NSView {
    public private(set) var material: OverlayMaterial
    public let contentView = NSView()
    /// Panels take clicks and hovers; a pure overlay (the drop target, a
    /// HUD) lets them through to the views beneath.
    public let isInteractive: Bool
    private var materialView: NSView?
    private var tintView: NSView?
    private let reduceTransparency: ReduceTransparency
    /// Pins one material (tests, `debug.drop_highlight`); nil follows this Mac.
    public var materialOverride: OverlayMaterial? {
        didSet { refreshMaterial() }
    }

    public var cornerRadius: CGFloat = Metrics.panelCornerRadius {
        didSet { if cornerRadius != oldValue { applyShape() } }
    }

    /// The vibrancy fallback blurs what is behind the window instead of the window's own
    /// content: set it for a surface that is the whole content of a clear window of its own
    /// (a hover card), where a blur within the window has nothing under it. Liquid Glass and
    /// the solid surface ignore it.
    public var samplesBehindWindow = false {
        didSet { if samplesBehindWindow != oldValue { (materialView as? NSVisualEffectView)?.blendingMode = blending } }
    }

    private var blending: NSVisualEffectView.BlendingMode { samplesBehindWindow ? .behindWindow : .withinWindow }

    /// `material` pins one material (tests, previews); nil follows
    /// `reduceTransparency` on this Mac.
    public init(material: OverlayMaterial? = nil, interactive: Bool = false,
                cornerRadius: CGFloat = Metrics.panelCornerRadius,
                reduceTransparency: ReduceTransparency = .shared) {
        materialOverride = material
        isInteractive = interactive
        self.cornerRadius = cornerRadius
        self.reduceTransparency = reduceTransparency
        self.material = material ?? Self.systemMaterial(reduceTransparency)
        super.init(frame: .zero)
        wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = [.width, .height]
        rebuild()
        reduceTransparency.register(self)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        let next = materialOverride ?? Self.systemMaterial(reduceTransparency)
        guard next != material else { return }
        material = next
        rebuild()
    }

    /// This Mac's material; `Glass.isLiquidGlassAvailable` also carries the
    /// Debug legacy-material switch.
    private static func systemMaterial(_ reduceTransparency: ReduceTransparency) -> OverlayMaterial {
        OverlayMaterial.select(liquidGlassAvailable: Glass.isLiquidGlassAvailable,
                               reduceTransparency: reduceTransparency.isEnabled)
    }

    private func rebuild() {
        // Moving the content out of the window resigns a focused field in it; it takes the keys back after.
        let focused = (window?.firstResponder as? NSView).flatMap { $0.isDescendant(of: contentView) ? $0 : nil }
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
            effect.blendingMode = blending
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
        // The glass panel lays its contentView out with constraints; out
        // of the glass it must size by its frame again.
        if material != .liquidGlass {
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentView.autoresizingMask = [.width, .height]
            tintView?.frame = view.bounds
            contentView.frame = view.bounds
        }
        // Below any view a caller added on the surface itself (the floating chat's grip).
        addSubview(view, positioned: .below, relativeTo: nil)
        materialView = view
        if let focused, let window = focused.window { window.makeFirstResponder(focused) }
        applyShape()
        applyTheme()
        // Content colors may depend on the material (a veil that only
        // glass needs): the content re-resolves them like on a theme change.
        let content = contentView
        ThemeRepaint.request(content, roots: { () -> [NSView] in [content] }, scope: nil, animated: false, layout: true, lazy: false)
    }

    private func applyShape() {
        if let glass = materialView as? GlassPanelView {
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
                (materialView as? GlassPanelView)?.tintColor = overlayTint
            case .vibrancy:
                tintView?.layer?.backgroundColor = overlayTint.cgColor
                materialView?.layer?.borderColor = Palette.separator.cgColor
            case .opaque:
                materialView?.layer?.backgroundColor = Palette.popupSurface.cgColor
                materialView?.layer?.borderColor = Borders.color(Palette.separator).cgColor
            }
        }
        applyShape()
    }

    /// The theme's glass tint, its alpha scaled by the overlay tint
    /// strength tunable (default 1.25, a little denser than the theme
    /// tint so text over busy content stays readable; 1 is unchanged).
    private var overlayTint: NSColor {
        let tint = Palette.glassTint
        let strength = ChromeTunables.glassOverlayTintStrength.value
        guard strength != 1 else { return tint }
        return tint.withAlphaComponent(min(max(tint.alphaComponent * strength, 0), 1))
    }
}

extension NSView {
    /// Paints this view, a system popover's content, with the solid popup
    /// surface of `scope`'s theme, so no text under the popover's vibrancy
    /// shows through. Call it each time the popover opens (it follows the
    /// theme then).
    public func fillWithPopupSurface(themeOf scope: NSView) {
        wantsLayer = true
        layer?.backgroundColor = scope.performWithTheme { Palette.popupSurface }.cgColor
    }

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
