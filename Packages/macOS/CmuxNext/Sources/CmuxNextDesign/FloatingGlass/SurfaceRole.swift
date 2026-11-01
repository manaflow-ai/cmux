// Follows schemas/surface-roles/surface-roles.json: change the JSON first, then this copy;
// scripts/cmux-next/check-surface-roles.py fails when the two differ.

public import CoreGraphics

/// The overlay surface roles: every popover, menu, card, toast, sheet and tooltip is one of these,
/// native and web (the webviews' `--surface-<role>-*`). Glass, never opaque: each role is glass, and
/// its text reads through the blur, tint and contrast inside the glass, never an opaque fill.
/// Reduce Transparency is the one opaque fallback (``OverlayMaterial/opaque``). Make a role's surface
/// with `Glass.makeSurface(_:content:)`.
public nonisolated enum SurfaceRole: String, CaseIterable, Sendable {
    /// Popovers, pickers, hover cards, find and prompt bars, page info and the palette.
    case popover
    /// Menus, context menus and dropdowns.
    case menu
    /// The sidebar's cards (Update Ready, the Updated card, notices and tips) over the sidebar's own glass.
    case card
    /// Toasts: a rounded rect, never a capsule, even on one line.
    case toast
    /// Dialogs, confirms, prompt bars and sheets: a little denser veil for longer text.
    case sheet
    /// Tooltips: the frost (TooltipSurface), the popup surface at the least alpha that keeps 4.5:1 over a blur.
    case tooltip

    /// The share of what is behind it at or above which a fill on an overlay reads as solid:
    /// check-overlay-glass.py and check-glass-never-opaque.ts fail one outside their allowlists.
    public static let nearOpaque: Double = 0.9

    /// The shared neutral glass the role draws; nil for a role on the theme's glass tint.
    public var neutralStyle: FloatingGlassStyle? {
        switch self {
        case .card: return .card
        case .toast: return .toast
        case .sheet: return .dialog
        default: return nil
        }
    }

    /// How the role tints its glass: the theme's tint, or its neutral glass with the rim.
    public var tone: OverlayTone {
        neutralStyle.map { .neutralGlass($0) } ?? .theme
    }

    /// The role's own corner radius; nil for one on the panel radius tunable
    /// (`Metrics.panelCornerRadius`).
    public var cornerRadius: CGFloat? {
        switch self {
        case .card: return 10
        case .toast: return 9
        case .sheet: return 14
        case .tooltip: return 5
        default: return nil
        }
    }

    /// Whether the role casts the popups' soft shadow (a floating panel); a card on the sidebar does not.
    public var castsShadow: Bool {
        [.popover, .menu, .toast, .sheet, .tooltip].contains(self)
    }

    /// What the role draws under Reduce Transparency, its one opaque path.
    public var reduceTransparencyFallback: String {
        switch self {
        case .popover: return "the opaque popup surface (--surface-popup) with its hairline"
        case .menu: return "the opaque popup surface (--surface-popup) with its hairline"
        case .card: return "the opaque elevated fill (Palette.elevatedBackground) with a hairline"
        case .toast: return "the opaque popup surface, no rim"
        case .sheet: return "the opaque popup surface, no rim"
        case .tooltip: return "the opaque popup surface (--tooltip-tint becomes --surface-popup)"
        }
    }
}

extension FloatingGlassStyle {
    /// The sidebar's cards (Update Ready, the Updated card, notices and tips) over the sidebar's own glass.
    nonisolated public static let card = FloatingGlassStyle(cornerRadius: 10, darkVeilAlpha: 0.22, lightVeilAlpha: 0.45,
                                                         darkRim: (0.22, 0.04), lightRim: (0.8, 0.08), castsShadow: false)
    /// Toasts: a rounded rect, never a capsule, even on one line.
    nonisolated public static let toast = FloatingGlassStyle(cornerRadius: 9, darkVeilAlpha: 0.42, lightVeilAlpha: 0.55,
                                                         darkRim: (0.3, 0.06), lightRim: (0.85, 0.1), castsShadow: true)
    /// Dialogs, confirms, prompt bars and sheets: a little denser veil for longer text.
    nonisolated public static let dialog = FloatingGlassStyle(cornerRadius: 14, darkVeilAlpha: 0.48, lightVeilAlpha: 0.62,
                                                         darkRim: (0.28, 0.05), lightRim: (0.85, 0.1), castsShadow: true)
}
