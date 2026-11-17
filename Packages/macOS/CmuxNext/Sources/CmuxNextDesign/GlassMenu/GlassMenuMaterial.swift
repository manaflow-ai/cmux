public import AppKit
import CmuxNextDesignTokens

/// The one floating material, native side: every cmux-drawn menu and popover (``GlassMenu``, and the
/// popovers made with ``Glass/makeMenuPanel(content:cornerRadius:)``) is the App's glass at the menu
/// level, the one popup radius, the AppKit row grid (``MenuMetrics``) and a veil of the theme surface
/// on the glass. The web's popups are the same surface (webviews ui/glass/glass.css GLASS LEVELS: the
/// menu level and `--host-glass-fill`), so a native menu and a web one side by side are one material.
///
/// Leo, 2026-11-11: "The point is, the styles mix and they don't look good. So they need to look
/// good." and, of rebuilding the account menu on our own glass: "Well, that's the whole point, right?
/// Like that's what we wanted to do anyways. have better design (systems too)".
///
/// The numbers are schemas/design-scale/design-scale.json's: the menu level's `veil`, the `popup`
/// named radius and the `row` control. webviews/test/floating-material-sync.test.ts fails when one
/// here differs from the JSON, so the page and the App cannot drift.
public nonisolated struct GlassMenuMaterial {
    public nonisolated init() {}
    /// The theme surface laid on the glass, percent (design-scale.json glass `menu` `veil`).
    public static let veilPercent: Double = 40
    /// The one popup radius when the person set no corner radius of their own (design-scale.json
    /// namedRadii `popup`; the native default outer radius, `MetricTunables.densityPaneCornerRadius`).
    public static let defaultCornerRadius: CGFloat = 8
    /// A menu row (design-scale.json controls `row`, `DesignTokens.controlRow`).
    @MainActor public static let rowHeight: CGFloat = DesignTokens.controlRow
    /// The glass level every menu and popover is.
    public static let level: GlassLevel = .menu

    /// The veil's share of the theme surface, 0...1.
    public static var veil: CGFloat { CGFloat(veilPercent / 100) }

    /// The radius in effect: the one surface radius, concentric with the panes (Lawrence
    /// 2026-11-04), which is ``defaultCornerRadius`` unless the person changed it.
    @MainActor public static var cornerRadius: CGFloat { PopupStyle.standard.cornerRadius }
}

extension Glass {
    /// A floating menu or popover's surface: the App's glass at the menu level in the one popup
    /// radius, with the menu veil (``GlassMenuVeilView``) under `content`. Every cmux-drawn popover
    /// uses it; standard right-click menus stay `NSMenu` (Lawrence 2026-10-23).
    @MainActor
    public static func makeMenuPanel(content: NSView? = nil, cornerRadius: CGFloat? = nil,
                                       interactive: Bool = true) -> OverlaySurfaceView {
        let surface = makeSurface(.menu, content: content, cornerRadius: cornerRadius ?? GlassMenuMaterial.cornerRadius,
                                  interactive: interactive)
        surface.tintLevel = GlassMenuMaterial.level
        let veil = GlassMenuVeilView(frame: surface.contentView.bounds)
        veil.autoresizingMask = [.width, .height]
        surface.contentView.addSubview(veil, positioned: .below, relativeTo: nil)
        return surface
    }
}

/// The theme surface at ``GlassMenuMaterial/veil`` over a menu's glass, under its rows: the same veil
/// the page lays on the App's glass under a web menu (`--host-glass-fill`). None on the opaque Reduce
/// Transparency surface, which is solid already. It never takes a click.
@MainActor
public final class GlassMenuVeilView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        let glass = enclosingOverlayMaterial.map { $0 != .opaque } ?? true
        layer?.backgroundColor = glass
            ? performWithTheme { Palette.surfaceBackground.withAlphaComponent(GlassMenuMaterial.veil) }.cgColor
            : NSColor.clear.cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
