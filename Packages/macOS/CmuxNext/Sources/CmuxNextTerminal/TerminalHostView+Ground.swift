public import AppKit
public import CmuxNextDesign

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

    /// An opaque window paints the terminal's theme background, like
    /// `GhosttyRuntime.backgroundColor`. Where the window is see-through
    /// (translucent, glass, or over art) the window root paints the one
    /// sheet and the host stays clear, as the panes around it do, unless the
    /// terminal's own theme differs from theirs: its background then lies over
    /// the glass at the window's tint (`WindowBackdrop.tintOpacity`). Over a
    /// background picture a terminal whose Ghostty config is opaque paints its
    /// own background solid, as Ghostty draws it (``keepsGhosttyBackground(over:in:)``).
    /// The user's terminal background (`appearance.surfaces.terminal`) replaces
    /// all of these; the surfaces then draw a transparent default background.
    func paintGround() {
        let (scope, tokens) = (themeScope, themeTokens)
        // The window root's backdrop (`WindowRootView.backdrop`): the scope's art and its own tint.
        let backdrop = WindowBackdrop(tokens, reduceTransparency: ReduceTransparency.shared.isEnabled,
                                      selection: scope.backdropSelection, tintOpacity: scope.backdropTintOpacity)
        // A pane whose ground a view above paints (a see-through floating pane's card): the surface draws a
        // transparent default background and the host paints none, so the text is solid over that one ground.
        // One walk of the superviews for a paint: the owner is read here and told below.
        let owner = superview == nil ? nil : paneGroundOwner
        let owned = owner?.ownsContentGround ?? false
        GhosttyRuntime.setSeeThrough(superview != nil && (owned || !backdrop.panesPaintBackground), host: self)
        let keepsOwn = Self.keepsGhosttyBackground(over: backdrop, in: scope)
        // Under an App Theme, a terminal on the terminal theme that shows the window through draws on the App Theme's
        // one veil (sidebar and panes alike), its colors raised to read on it; on an opaque window, on its own solid
        // background over a picture, or with its own theme it keeps its own background and colors.
        let veil = !backdrop.panesPaintBackground && !keepsOwn && theme == nil && scope.store.appTheme != nil
        onVeil?(veil ? superview?.themeTokens.windowBackground.withAlpha(1) : nil)
        let given = owned ? hatchGround : nil
        if given != ownedGround {
            ownedGround = given
            if owned { owner?.contentGroundDidChange() }
        }
        if owned {
            layer?.backgroundColor = nil
            return
        }
        let fill = performWithTheme { Palette.surfaceOverride(.terminal) }
        if let fill {
            layer?.backgroundColor = fill.cgColor
            return
        }
        guard !backdrop.panesPaintBackground, !keepsOwn else {
            // The program set its own background (OSC 11): the host beside the surface (a held frame's grow strip) has
            // the colour of its empty cells. Over a picture the surfaces draw a transparent default background
            // (`GhosttyRuntimeSurfacePolicy`), so this is the background under every cell.
            layer?.backgroundColor = current?.session?.model.backgroundOverride?.cgColor
                ?? (keepsOwn ? Self.solidGround(theme) : Self.opaqueGround(theme))
            return
        }
        let around = superview?.themeTokens.surfaceBackground.withAlpha(1)
        let own = tokens.surfaceBackground.withAlpha(1)
        layer?.backgroundColor = theme == nil || own == around ? nil : own.withAlpha(backdrop.tintOpacity).cgColor
    }

    /// The terminal background under the Sized for hatch: the user's terminal surface color, else the program's
    /// own (OSC 11), else the theme's or the config's.
    var hatchGround: CGColor {
        performWithTheme { Palette.surfaceOverride(.terminal) }?.cgColor
            ?? current?.session?.model.backgroundOverride?.cgColor
            ?? Self.opaqueGround(theme)
    }

    /// The background of `theme`'s empty cells, else the config's (``ground(theme:in:)`` gives a waiting pane the same).
    static func opaqueGround(_ theme: GhosttyThemeConfig?) -> CGColor {
        guard let rgb = theme?.colors?.background else { return GhosttyRuntime.shared.backgroundColor.cgColor }
        return CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1) // colour-allow: the theme's own background, no raw value (moved from TerminalHostView.swift)
    }
}

/// In a pane whose ground a view above paints (a floating pane with a see-through background), the host paints no
/// ground and gives the one it would paint, so the owner paints the terminal's own colour under the text.
extension TerminalHostView: PaneGroundFollowing, PaneGroundReporting {
    public func paneGroundOwnerChanged() { paintGround() }
    public var paneGround: CGColor? { ownedGround }
}
