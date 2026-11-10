public import AppKit
import CmuxNextDesign

extension TerminalHostView {
    /// The ground a terminal with `theme` (nil: the config's) paints in `view`'s scope before its program sets one (OSC
    /// 11): the user's terminal background (`appearance.surfaces.terminal`), else, where panes paint their background, its
    /// theme's, else the config's. Nil over a see-through window, where a terminal leaves the window's sheet showing.
    /// A pane whose terminal is not made yet (a split's stand-in, made after its key's frame) shows it from the key's
    /// frame, not the window's color (SPLIT NEW PANE GROUND, m81); the terminal's host paints the same when it comes in.
    public static func ground(theme: GhosttyThemeConfig?, in view: NSView) -> CGColor? {
        if let fill = view.performWithTheme({ Palette.surfaceOverride(.terminal) }) { return fill.cgColor }
        let scope = view.themeScope
        let backdrop = WindowBackdrop(scope.tokens, reduceTransparency: ReduceTransparency.shared.isEnabled,
                                      selection: scope.backdropSelection, tintOpacity: scope.backdropTintOpacity)
        return backdrop.panesPaintBackground ? opaqueGround(theme) : nil
    }

    /// The background of `theme`'s empty cells, else the config's.
    static func opaqueGround(_ theme: GhosttyThemeConfig?) -> CGColor {
        guard let rgb = theme?.colors?.background else { return GhosttyRuntime.shared.backgroundColor.cgColor }
        return CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
