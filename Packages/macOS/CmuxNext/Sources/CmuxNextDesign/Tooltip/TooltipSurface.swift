public import CmuxTheme
public import Foundation
public import CmuxNextDesignTokens

/// The one tooltip surface, native and pages (Leo, 2026-10-14): frosted
/// glass, a strong blur under a tint dense enough that the text reads over
/// anything, a one-device-pixel rim in the separator color and a small tight
/// shadow. Reduce Transparency draws the opaque popup surface instead.
///
/// The tint is the popup surface (`opaqueOverlayFill`) at `tintAlpha`: the
/// least alpha, from `minimumTintAlpha` up to `maximumTintAlpha`, at which the
/// ink keeps 4.5:1 over the tint laid on pure black and on pure white. The
/// blur only averages what is under it, so those two are the worst a backdrop
/// can do. A low-contrast theme (Solarized dark) reaches no such alpha: its
/// tint is first walked away from the ink, then its ink toward the ink's own
/// extreme, until one does, so the tooltip is glass in every theme, never the
/// solid popup surface (Codex review of #23970). Pages get the tint as
/// `--cmux-tooltip-tint` and the ink as `--cmux-tooltip-ink` (`WebTheme`) and
/// the rest from pages/shared/desktop.css (`--tooltip-*`); a web test reads
/// these constants and fails when the two drift.
public nonisolated struct TooltipSurface: Hashable, Sendable {
    /// The blur under the tint, in points (pages: `--tooltip-blur`). The
    /// native panel's `NSVisualEffectView` blurs by its material; this is
    /// the pages' radius, matched to it by eye.
    public static let blurRadius: Double = 24
    /// The least tint alpha (pages' fallback without the host's tint:
    /// `--tooltip-tint`): dense enough that the glass reads as a surface,
    /// light enough that the backdrop's color shows. The 4.5:1 rule decides
    /// above it (about 0.7 dark, 0.6 light; Leo 2026-10-18: tooltips were too opaque at 0.86).
    public static let minimumTintAlpha: Double = 0.6
    /// The most tint alpha: above it the tooltip reads as a solid card, not glass (Leo: glass,
    /// never opaque). A theme that needs more moves its tint and ink instead (`legible`).
    public static let maximumTintAlpha: Double = 0.9
    /// The shadow: elevation 1, small and tight (`--elevation-1` in pages).
    @MainActor public static var shadow: Elevation { PopupStyle.elevation1 }

    /// The opaque popup surface: the whole surface under Reduce Transparency.
    public var fill: ThemeRGB
    /// The text color the surface carries: the theme's, unless it misses 4.5:1 over `fill` (the
    /// Reduce Transparency surface) or no tint up to `maximumTintAlpha` reads under it; then walked
    /// toward its extreme until both hold.
    public var ink: ThemeRGB
    /// The glass's tint: translucent, at most `maximumTintAlpha`, and `ink` keeps 4.5:1 over it
    /// laid on any backdrop.
    public var tint: ThemeRGB

    public init(fill: ThemeRGB, ink: ThemeRGB) {
        self.fill = fill.withAlpha(1)
        let legible = Self.legible(fill: self.fill, ink: ink.withAlpha(1))
        self.ink = legible.ink
        tint = legible.tint
    }

    /// The surface for a theme.
    public init(_ tokens: ThemeTokens, lift: Double) {
        self.init(fill: tokens.opaqueOverlayFill(lift: lift), ink: tokens.textPrimary)
    }

    /// The ink and the tint for `fill` and `ink`. The ink must keep 4.5:1 over `fill` itself, the
    /// opaque surface Reduce Transparency draws under the same ink (Codex review of #23970: #839496
    /// over #0A333E read 4.27:1 there), so an ink that misses is first walked toward its own extreme
    /// (white or black), in 1% steps, until it reads. The tint is then `fill` at `tintAlpha` when it
    /// has one; else its color is walked away from the ink until it has one; at that extreme, the
    /// ink is walked further toward its own. A fill no walked ink reads on (mid grey under white)
    /// takes the extreme ink that reads best on it over the opposite extreme's tint, which reads at
    /// `minimumTintAlpha` over any backdrop, so the result is always translucent.
    public static func legible(fill: ThemeRGB, ink: ThemeRGB) -> (ink: ThemeRGB, tint: ThemeRGB) {
        let lightInk = ink.relativeLuminance >= fill.relativeLuminance
        let away: ThemeRGB = lightInk ? .black : .white
        let inkPole: ThemeRGB = lightInk ? .white : .black
        let opaque = (0...100).lazy.map { ink.mixed(toward: inkPole, Double($0) / 100) }.first { reads($0, over: fill) }
        if let ink = opaque {
            for step in 0...100 {
                let color = fill.mixed(toward: away, Double(step) / 100)
                if let alpha = tintAlpha(fill: color, ink: ink) { return (ink, color.withAlpha(alpha)) }
            }
            for step in 1...100 {
                let moved = ink.mixed(toward: inkPole, Double(step) / 100)
                if let alpha = tintAlpha(fill: away, ink: moved) { return (moved, away.withAlpha(alpha)) }
            }
        }
        let pole: ThemeRGB = ThemeRGB.white.contrast(with: fill) >= ThemeRGB.black.contrast(with: fill) ? .white : .black
        let under: ThemeRGB = pole == .white ? .black : .white
        return (pole, under.withAlpha(tintAlpha(fill: under, ink: pole) ?? minimumTintAlpha))
    }

    /// `ink` keeps 4.5:1 over the opaque `fill`, as drawn and as rounded for pages.
    static func reads(_ ink: ThemeRGB, over fill: ThemeRGB) -> Bool {
        min(ink.contrast(with: fill), WebTheme.cssRounded(ink).contrast(with: WebTheme.cssRounded(fill)))
            >= ThemeTokens.minimumTextContrast
    }

    /// The least alpha from `minimumTintAlpha` to `maximumTintAlpha` (in 1% steps) at which `ink`
    /// keeps 4.5:1 over `fill` laid on black and on white, as the native panel draws them and as
    /// pages get them (`WebTheme.cssRounded`: 8-bit channels; Codex review of #23970, Solarized
    /// light read 4.500:1 native but 4.485:1 once rounded for pages); nil when none does.
    public static func tintAlpha(fill: ThemeRGB, ink: ThemeRGB) -> Double? {
        let least = Int((minimumTintAlpha * 100).rounded())
        let most = Int((maximumTintAlpha * 100).rounded())
        let pageInk = WebTheme.cssRounded(ink)
        for percent in least...most {
            let tint = fill.withAlpha(Double(percent) / 100)
            if min(worstContrast(ink: ink, tint: tint), worstContrast(ink: pageInk, tint: WebTheme.cssRounded(tint)))
                >= ThemeTokens.minimumTextContrast { return tint.alpha }
        }
        return nil
    }

    /// `ink`'s contrast over `tint` on the worst backdrop: pure black or pure white.
    public static func worstContrast(ink: ThemeRGB, tint: ThemeRGB) -> Double {
        let black = ThemeRGB(hex: 0x000000)
        let white = ThemeRGB(hex: 0xFFFFFF)
        return min(ink.contrast(with: tint.composited(over: black)), ink.contrast(with: tint.composited(over: white)))
    }
}
