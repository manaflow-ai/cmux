public import CmuxTheme
public import Foundation

/// The one tooltip surface, native and pages (Leo, 2026-10-14): frosted
/// glass, a strong blur under a tint dense enough that the text reads over
/// anything, a one-device-pixel rim in the separator color and a small tight
/// shadow. Reduce Transparency draws the opaque popup surface instead.
///
/// The tint is the popup surface (`opaqueOverlayFill`) at `tintAlpha`: the
/// least alpha, from `minimumTintAlpha` up, at which the primary text keeps
/// 4.5:1 over the tint laid on pure black and on pure white. The blur only
/// averages what is under it, so those two are the worst a backdrop can do.
/// Pages get the tint as `--cmux-tooltip-tint` (`WebTheme`) and the rest
/// from pages/shared/desktop.css (`--tooltip-*`); a web test reads these
/// constants and fails when the two drift.
public nonisolated struct TooltipSurface: Hashable, Sendable {
    /// The blur under the tint, in points (pages: `--tooltip-blur`). The
    /// native panel's `NSVisualEffectView` blurs by its material; this is
    /// the pages' radius, matched to it by eye.
    public static let blurRadius: Double = 24
    /// The least tint alpha (pages' fallback without the host's tint:
    /// `--tooltip-tint`): dense enough that the glass reads as a surface,
    /// light enough that the backdrop's color shows.
    public static let minimumTintAlpha: Double = 0.86
    /// The shadow: elevation 1, small and tight (`--elevation-1` in pages).
    @MainActor public static var shadow: Elevation { PopupStyle.elevation1 }

    /// The opaque popup surface: the tint at alpha 1, and the whole surface under Reduce Transparency.
    public var fill: ThemeRGB
    /// The text color the surface must carry.
    public var ink: ThemeRGB
    /// The fill at the least alpha that keeps `ink` readable over any backdrop.
    public var tint: ThemeRGB

    public init(fill: ThemeRGB, ink: ThemeRGB) {
        self.fill = fill.withAlpha(1)
        self.ink = ink.withAlpha(1)
        tint = self.fill.withAlpha(Self.tintAlpha(fill: self.fill, ink: self.ink))
    }

    /// The surface for a theme.
    public init(_ tokens: ThemeTokens, lift: Double) {
        self.init(fill: tokens.opaqueOverlayFill(lift: lift), ink: tokens.textPrimary)
    }

    /// The least alpha from `minimumTintAlpha` (in 1% steps) at which `ink`
    /// keeps 4.5:1 over `fill` laid on black and on white; 1 when none does.
    public static func tintAlpha(fill: ThemeRGB, ink: ThemeRGB) -> Double {
        for percent in Int((minimumTintAlpha * 100).rounded())..<100 {
            let alpha = Double(percent) / 100
            if worstContrast(ink: ink, tint: fill.withAlpha(alpha)) >= ThemeTokens.minimumTextContrast { return alpha }
        }
        return 1
    }

    /// `ink`'s contrast over `tint` on the worst backdrop: pure black or pure white.
    public static func worstContrast(ink: ThemeRGB, tint: ThemeRGB) -> Double {
        let black = ThemeRGB(hex: 0x000000)
        let white = ThemeRGB(hex: 0xFFFFFF)
        return min(ink.contrast(with: tint.composited(over: black)), ink.contrast(with: tint.composited(over: white)))
    }
}
