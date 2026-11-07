public import AppKit
import CmuxTheme
import CmuxNextDesignTokens

extension Palette {
    /// A toast's text: `ink` fitted to read at 4.5:1 (a tertiary hint at 3:1) on the ground the toast
    /// shows: its neutral glass, the veil over the window (``FloatingGlassStyle/toast``), or the solid
    /// popup surface when `reduceTransparency` is on. One ink cannot always read on both: Hot Dog
    /// Stand's veil darkens its red, so only white reads there, and its solid surface lifts the red,
    /// so only black reads there. A theme's text that already reads is kept as it is. theme-scoped
    /// - Parameters:
    ///   - ink: the theme text colour the label draws.
    ///   - reduceTransparency: decides which ground the toast shows; the toast passes its own.
    /// - Returns: the colour to draw.
    public static func toastText(_ ink: ThemeInk, reduceTransparency: ReduceTransparency = .shared) -> NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let ground: ThemeRGB
        if reduceTransparency.isEnabled {
            // glass-opaque-allow: a contrast reference only (the Reduce Transparency surface); nothing paints it here
            ground = tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)
        } else {
            let veil = FloatingGlassStyle.toast.look(isDark: tokens.isDark).veil
            ground = ThemeRGB(red: veil.white, green: veil.white, blue: veil.white, alpha: veil.alpha)
                .composited(over: tokens.windowBackground.withAlpha(1))
        }
        return CmuxDialogButtonLook.readable(ink.rgb(tokens).withAlpha(1), over: [ground], minimum: ink.minimumContrast).nsColor
    }

    /// A sheet's or dialog's text: `ink` fitted to read on the dialog card
    /// (``CmuxDialogButtonLook/cardSurfaces(_:lift:)``), as its buttons are. theme-scoped
    /// - Parameter ink: the theme text colour the label draws.
    /// - Returns: the colour to draw.
    public static func sheetText(_ ink: ThemeInk) -> NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        return CmuxDialogButtonLook.readable(ink.rgb(tokens).withAlpha(1), over: CmuxDialogButtonLook.cardSurfaces(tokens),
                                             minimum: ink.minimumContrast).nsColor
    }
}
