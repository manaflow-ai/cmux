public import AppKit
import CmuxTheme
import CmuxNextDesignTokens

extension Palette {
    /// A toast's text: `ink` fitted to read on the toast's neutral glass, its veil over the window
    /// (``FloatingGlassStyle/toast``) and the solid popup surface under Reduce Transparency, at 4.5:1
    /// (a tertiary hint at 3:1). A theme's text that already reads there is kept as it is. theme-scoped
    /// - Parameter ink: the theme text colour the label draws.
    /// - Returns: the colour to draw.
    public static func toastText(_ ink: ThemeInk) -> NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let veil = FloatingGlassStyle.toast.look(isDark: tokens.isDark).veil
        let glass = ThemeRGB(red: veil.white, green: veil.white, blue: veil.white, alpha: veil.alpha)
        // glass-opaque-allow: contrast references only (the veil over the window, the Reduce Transparency surface); nothing paints them here
        let grounds = [glass.composited(over: tokens.windowBackground.withAlpha(1)), tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)]
        return CmuxDialogButtonLook.readable(ink.rgb(tokens).withAlpha(1), over: grounds, minimum: ink.minimumContrast).nsColor
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
