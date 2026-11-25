public import AppKit

extension Glass {
    /// The tooltip's whole surface as ``TooltipPanel`` draws it, for a view that is not the tooltip
    /// window: the tooltip's glass, the contrast-fitted legibility tint over it (``TooltipStyle/tint``,
    /// none on the opaque Reduce Transparency surface, which is solid already) and its small tight
    /// shadow (``TooltipSurface/shadow``). The App draws it under a web tooltip that asks for host
    /// glass (`data-host-glass="chip"`, ``makeHostSurface(level:role:)``) and as the native tooltip of
    /// the Liquid Glass Parity playground, so the web tooltip lays only its text on the native surface.
    ///
    /// `look` is the shared hover surface it draws (``HoverSurfaceLook``); nil takes the setting's.
    @MainActor
    public static func makeTooltipGlass(cornerRadius: CGFloat? = nil, interactive: Bool = false,
                                        look: HoverSurfaceLook? = nil) -> OverlaySurfaceView {
        let look = look ?? HoverSurfaceLook.current
        let surface = makeSurface(.tooltip, cornerRadius: cornerRadius ?? SurfaceRole.tooltip.cornerRadius, interactive: interactive)
        look.apply(to: surface)
        let veil = TooltipLegibilityView(frame: surface.contentView.bounds)
        veil.autoresizingMask = [.width, .height]
        surface.contentView.addSubview(veil, positioned: .below, relativeTo: nil)
        surface.castShadow = look.shadow(default: TooltipSurface.shadow)
        return surface
    }
}

/// The tooltip's legibility tint over its glass, under its text (``TooltipPanel/legibility``), in the
/// theme scope it sits in. It never takes a click.
@MainActor
final class TooltipLegibilityView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        let glass = enclosingOverlayMaterial.map { $0 != .opaque } ?? true
        layer?.backgroundColor = glass ? performWithTheme { TooltipStyle.current().tint }.cgColor : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}
