import Foundation

/// The sidebar's own ink, measured on the Codex desktop sidebar (https://github.com/manaflow-ai/cmux/issues/39956,
/// values from https://github.com/manaflow-ai/cmux/issues/28793 and the app's stylesheet): row titles in a softer
/// foreground than the chrome's primary text (`--app-color-text-foreground`, #dfdfdf on a dark ground: the pure
/// foreground 12% of the way to the background).
extension ThemeTokens {
    /// How far a sidebar row title moves from the primary text toward the background, at most.
    public static let sidebarTitleSoftening = 0.12

    /// A sidebar row's title: the primary text softened toward the background by up to
    /// ``sidebarTitleSoftening``, never under 4.5:1 on the strongest row fill or the bare background, and in a
    /// see-through window also over the worst desktop behind it (``seeThroughSurfaces(bg:opacity:isDark:fills:)``).
    public var sidebarTitle: ThemeRGB {
        let bg = windowBackground.withAlpha(1)
        let surfaces = [bg, selectionFill.composited(over: bg), pressedFill.composited(over: bg)]
            + Self.seeThroughSurfaces(bg: bg, opacity: backgroundOpacity, isDark: isDark, fills: [pressedFill, selectionFill])
        let worst = surfaces.min { textPrimary.contrast(with: $0) < textPrimary.contrast(with: $1) } ?? bg
        return Self.muted(textPrimary, toward: bg, upTo: Self.sidebarTitleSoftening, over: worst,
                          minimum: Self.minimumTextContrast)
    }
}
