public import AppKit

/// Liquid Glass helpers. Only this module touches the native glass API
/// (`NSGlassEffectView`, macOS 26 and later); everything else gets a
/// `GlassPanelView`, which draws the same shape and tint with
/// `NSVisualEffectView` before macOS 26.
///
/// Use glass for chrome only (sidebar, tab strip, palette, popovers), never
/// over terminal content. When several glass panels sit near each other,
/// wrap them in `makeContainer` so AppKit merges and batches their rendering.
public struct Glass {
    public init() {}
    public enum Style: Sendable {
        case regular
        case clear
    }

    /// Whether this Mac draws Liquid Glass: macOS 26 and later. Debug
    /// builds force the older material with
    /// `CMUX_NEXT_DEBUG_LEGACY_MATERIAL=1` (read once at launch), so the
    /// macOS 14 and 15 look can be checked on a macOS 26 host.
    nonisolated public static let isLiquidGlassAvailable: Bool = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_NEXT_DEBUG_LEGACY_MATERIAL"] == "1" { return false }
        #endif
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }()

    /// A floating panel over content that carries text (palette, dialogs,
    /// hover cards, find and prompt bars, page info, popovers, menus) and
    /// hosts `content` edge to edge: Liquid Glass tinted with the theme, with
    /// its own refracting rim, like iOS's menus and folders (Leo, 2026-10-18,
    /// replacing the solid surface of 2026-10-12); the frosted vibrancy
    /// material before macOS 26, and the solid popup surface only under
    /// Reduce Transparency. It follows the theme live. Use this for every
    /// overlay; it takes clicks unless `interactive` is false. `tone`
    /// `.neutral` draws the shared neutral glass with its rim
    /// (``FloatingGlassStyle``: dialogs, prompts, toasts) instead of the theme
    /// tint.
    ///
    /// Glass, never a solid card (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE
    /// GLASS, SO JUST USE GLASS."): `cardFill` defaults to false. True lays the
    /// mostly opaque ``CardMaterial`` fill on the glass (ccde782cb51, 2026-10-20),
    /// which no overlay uses now; `check-overlay-glass.py` refuses a new one
    /// without a `glass-opaque-allow:` reason, and `FloatingSurfacesStayGlassTests`
    /// fails when an overlay paints denser than the shared glass.
    public static func makeOverlayPanel(
        content: NSView? = nil,
        cornerRadius: CGFloat = Metrics.panelCornerRadius,
        interactive: Bool = true,
        tone: OverlayTone = .theme,
        cardFill: Bool = false,
        activeLook: ActiveLookScope? = nil
    ) -> OverlaySurfaceView {
        let surface = OverlaySurfaceView(interactive: interactive, cornerRadius: cornerRadius,
                                         card: tone.style == nil && cardFill, tone: tone, activeLook: activeLook)
        surface.translatesAutoresizingMaskIntoConstraints = false
        if let content {
            content.translatesAutoresizingMaskIntoConstraints = true
            content.autoresizingMask = [.width, .height]
            content.frame = surface.contentView.bounds
            surface.contentView.addSubview(content)
        }
        return surface
    }

    /// The glass surface of one overlay role (``SurfaceRole``: popover, menu, card, toast, sheet,
    /// tooltip): `makeOverlayPanel` in the role's tone, never a solid card. Under Reduce Transparency
    /// it is the role's one opaque fallback. `cornerRadius` defaults to the panel radius, as
    /// `makeOverlayPanel`'s does.
    public static func makeSurface(
        _ role: SurfaceRole,
        content: NSView? = nil,
        cornerRadius: CGFloat = Metrics.panelCornerRadius,
        interactive: Bool = true,
        activeLook: ActiveLookScope? = nil
    ) -> OverlaySurfaceView {
        makeOverlayPanel(content: content, cornerRadius: cornerRadius, interactive: interactive, tone: role.tone,
                         activeLook: activeLook)
    }

    /// A raw glass panel that hosts `content` edge to edge (Liquid Glass,
    /// or the same shape in `NSVisualEffectView` before macOS 26). It has
    /// no Reduce Transparency fallback: floating overlays use
    /// `makeOverlayPanel` instead.
    public static func makePanel(
        content: NSView? = nil,
        style: Style = .regular,
        cornerRadius: CGFloat = Metrics.panelCornerRadius,
        interactive: Bool = false,
        activeLook: ActiveLookScope? = nil
    ) -> GlassPanelView {
        let glass = GlassPanelView(style: style, cornerRadius: cornerRadius, interactive: interactive, activeLook: activeLook)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.tintColor = Palette.glassTint
        glass.contentView = content
        return glass
    }

    /// A container that merges nearby glass panels and batches rendering
    /// (`NSGlassEffectContainerView`); before macOS 26 a plain view that
    /// hosts `content` edge to edge.
    public static func makeContainer(content: NSView, spacing: CGFloat = 0) -> NSView {
        if #available(macOS 26.0, *), isLiquidGlassAvailable {
            let container = NSGlassEffectContainerView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.spacing = spacing
            container.contentView = content
            return container
        }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}
