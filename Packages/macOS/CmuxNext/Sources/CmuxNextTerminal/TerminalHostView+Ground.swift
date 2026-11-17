public import AppKit
import CmuxNextDesign

extension TerminalHostView {
    /// The ground a terminal with `theme` (nil: the config's) paints in `view`'s scope before its program sets one (OSC
    /// 11): the user's terminal background (`appearance.surfaces.terminal`), else, where panes paint their background or
    /// the terminal keeps its Ghostty background over a picture (``keepsGhosttyBackground(over:in:)``), its theme's,
    /// else the config's. Nil over a see-through window, where a terminal leaves the window's sheet showing.
    /// A pane whose terminal is not made yet (a split's stand-in, made after its key's frame) shows it from the key's
    /// frame, not the window's color (SPLIT NEW PANE GROUND, m81); the terminal's host paints the same when it comes in.
    public static func ground(theme: GhosttyThemeConfig?, in view: NSView) -> CGColor? {
        if let fill = view.performWithTheme({ Palette.surfaceOverride(.terminal) }) { return fill.cgColor }
        let scope = view.themeScope
        let backdrop = WindowBackdrop(scope.tokens, reduceTransparency: ReduceTransparency.shared.isEnabled,
                                      selection: scope.backdropSelection, tintOpacity: scope.backdropTintOpacity)
        if backdrop.panesPaintBackground { return opaqueGround(theme) }
        return keepsGhosttyBackground(over: backdrop, in: scope) ? solidGround(theme) : nil
    }

    /// Whether a terminal in a window over a background picture draws its own Ghostty background, solid, as Ghostty
    /// does, instead of the picture at the window's tint: the Ghostty config files' `background-opacity` is 1
    /// (Ghostty's default) and the user set no terminal background of their own (`appearance.surfaces.terminal`).
    /// The picture then shows in the sidebar, the chrome and the other panes (user, Nov 17: "colors between ghostty
    /// and cmux-next are definitely still different": over the picture at 0.85 the terminal's #272822 measured
    /// #3a3d3b on average, and every cell a program paints in the theme background stood out as a dark patch).
    /// A Ghostty config with `background-opacity` under 1 asks for a see-through terminal, as in Ghostty itself.
    static func keepsGhosttyBackground(over backdrop: WindowBackdrop, in scope: ThemeScope) -> Bool {
        backdrop.selection != nil && !backdrop.panesPaintBackground && !scope.surfaceBackgrounds.overridesTerminal
            && GhosttyConfigBackground.loaded.opacity >= 1
    }

    /// `theme`'s background (nil: the config's) at full opacity, whatever the window's opacity: the color Ghostty
    /// fills an opaque terminal with.
    static func solidGround(_ theme: GhosttyThemeConfig?) -> CGColor {
        guard let rgb = theme?.colors?.background ?? GhosttyRuntime.shared.themeColors?.background else { return opaqueGround(theme) }
        return ThemeRGB(r: rgb.r, g: rgb.g, b: rgb.b).cgColor
    }
}
