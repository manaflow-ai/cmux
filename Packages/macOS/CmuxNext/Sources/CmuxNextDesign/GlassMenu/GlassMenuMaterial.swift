public import AppKit
public import CmuxNextDesignTokens
public import CmuxTheme

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
    public static let veilPercent: Double = TransientMaterial.standard.hostVeil * 100
    /// The one popup radius when the person set no corner radius of their own (design-scale.json
    /// namedRadii `popup`; the native default outer radius, `MetricTunables.densityPaneCornerRadius`).
    public static let defaultCornerRadius: CGFloat = 8
    /// A menu row (design-scale.json controls `row`, `DesignTokens.controlRow`).
    @MainActor public static let rowHeight: CGFloat = DesignTokens.controlRow
    /// The glass level every menu and popover is.
    public static let level: GlassLevel = .menu

    /// The veil's share of the theme surface, 0...1: the shared material's, which most themes keep (``veil(for:)``).
    public static var veil: CGFloat { CGFloat(veilPercent / 100) }

    /// The most a theme's veil rises to: the glass rule's 90% cap (design/glass-system.md), so a menu stays glass.
    public static let maximumVeil: CGFloat = 0.9

    /// What ``veil(for:)`` asks above each contrast floor, so the floor still holds once the glass is drawn in 8 bits.
    public static let contrastHeadroom = 0.1

    /// The veil `tokens` lay on a menu's glass: ``veil``, raised in 2% steps up to ``maximumVeil`` until the theme's
    /// primary text reads at 4.5:1 and its secondary at 3:1 on the glass over the theme's own window, a white page
    /// and a black page (design/glass-system.md, rule 5: when a level fails at its tint, the tint goes up, the text
    /// never gets thinner). At 40% Rose Pine Dawn's text read 2.56:1 on its glass over a black page and Red Planet's
    /// 2.62:1 over a white one (NativeControlContrastAuditTests); a theme whose text already reads there keeps 40%.
    /// Each floor carries ``contrastHeadroom``: Blue Dolphin's text fit to exactly 4.5:1 read 4.49:1 in the 8-bit capture.
    ///
    /// A theme whose own text reads under 4.5:1 on its surface asks only what the surface gives, less 0.05.
    public static func veil(for tokens: ThemeTokens) -> CGFloat {
        let pages = [tokens.windowBackground.withAlpha(1), ThemeRGB(red: 1, green: 1, blue: 1), ThemeRGB(red: 0, green: 0, blue: 0)]
        let surface = tokens.surfaceBackground.withAlpha(1)
        let primary = tokens.textPrimary.composited(over: surface)
        let secondary = tokens.textSecondary.composited(over: surface)
        let wants = (primary: min(4.5 + contrastHeadroom, primary.contrast(with: surface) - 0.05),
                     secondary: min(3.0 + contrastHeadroom, secondary.contrast(with: surface) - 0.05))
        var share = veil
        while share < maximumVeil {
            let grounds = pages.map { glass(tokens, veil: share, over: $0) }
            if grounds.allSatisfy({ primary.contrast(with: $0) >= wants.primary && secondary.contrast(with: $0) >= wants.secondary }) {
                break
            }
            share = min(maximumVeil, share + 0.02)
        }
        return share
    }

    /// A menu's glass over `page`, as the audit and the button looks model it: the theme's glass tint at the menu level,
    /// then the theme surface at `veil`.
    public static func glass(_ tokens: ThemeTokens, veil: CGFloat, over page: ThemeRGB) -> ThemeRGB {
        let tint = tokens.glassTint.withAlpha(min(1, tokens.glassTint.alpha * level.tintStrength))
        return tokens.surfaceBackground.withAlpha(Double(veil)).composited(over: tint.composited(over: page))
    }

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

/// The theme surface at ``GlassMenuMaterial/veil(for:)`` over a menu's glass, under its rows: the same veil
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
            ? performWithTheme {
                Palette.surfaceBackground.withAlphaComponent(GlassMenuMaterial.veil(for: ThemeContext.active ?? ThemeScope.app.tokens))
            }.cgColor
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
