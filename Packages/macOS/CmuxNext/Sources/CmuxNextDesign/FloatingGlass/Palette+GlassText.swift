public import AppKit
import CmuxTheme
import CmuxNextDesignTokens

extension Palette {
    /// A toast's text: `ink` fitted to read at 4.5:1 (a tertiary hint at 3:1) on the ground the toast
    /// shows: its glass, the veil over the window (``FloatingGlassStyle/toast``, the theme's tint), or the solid
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
            ground = Self.veilRGB(of: .toast, tokens: tokens).composited(over: tokens.windowBackground.withAlpha(1))
        }
        return CmuxDialogButtonLook.readable(ink.rgb(tokens).withAlpha(1), over: [ground], minimum: ink.minimumContrast).nsColor
    }

    /// The veil a neutral glass style lays over its glass: the gray, or with
    /// ``FloatingGlassStyle/veilTakesThemeTint`` the theme's glass tint at the same opacity. It reads
    /// the theme in effect, as ``toastText(_:reduceTransparency:)`` does, so the veil painted and the
    /// ground the text is fitted to are one colour. theme-scoped
    /// - Parameter style: the neutral glass style.
    /// - Returns: the colour to paint.
    public static func veil(of style: FloatingGlassStyle) -> NSColor {
        veilRGB(of: style, tokens: ThemeContext.active ?? ThemeScope.app.tokens).nsColor
    }

    /// ``veil(of:)`` as a colour value of `tokens`, for contrast checks.
    static func veilRGB(of style: FloatingGlassStyle, tokens: ThemeTokens) -> ThemeRGB {
        let veil = style.look(isDark: tokens.isDark).veil
        guard style.veilTakesThemeTint else {
            return ThemeRGB(red: veil.white, green: veil.white, blue: veil.white, alpha: veil.alpha)
        }
        return tokens.glassTint.withAlpha(veil.alpha)
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
