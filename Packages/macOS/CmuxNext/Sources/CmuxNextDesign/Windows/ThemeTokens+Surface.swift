public import CmuxTheme


extension ThemeTokens {
    /// The one background of every window and the surfaces on it
    /// (plans/cmux-next/windows.md): the terminal background with its
    /// `background-opacity`. Views on it draw nothing of their own (clear)
    /// or exactly this.
    public nonisolated var surfaceBackground: ThemeRGB { windowBackground }

    /// A card on the surface (Settings groups): the theme's foreground at
    /// a low alpha, a tint over whatever the surface shows. Over an opaque
    /// window it composites to exactly `chromeBackground` (the background
    /// mixed toward the foreground); over a see-through one it tints the
    /// window's one backdrop at the window's opacity instead of covering it
    /// with an opaque fill (Lawrence R48).
    public nonisolated var cardFill: ThemeRGB { hoverFill.withAlpha(isDark ? 0.05 : 0.035) }

    /// A scrim for text over the window's backdrop (the Home people list):
    /// the surface background at ``legibilityScrimOpacity``, laid over the
    /// window's tint. The background image still shows through; over an
    /// opaque window it composites to the background itself.
    public nonisolated var legibilityScrim: ThemeRGB { surfaceBackground.withAlpha(Self.legibilityScrimOpacity) }

    /// How much of the surface background ``legibilityScrim`` adds.
    public nonisolated static let legibilityScrimOpacity = 0.35
}
