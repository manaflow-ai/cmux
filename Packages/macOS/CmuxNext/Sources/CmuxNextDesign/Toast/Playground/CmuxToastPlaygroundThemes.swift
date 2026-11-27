public import CmuxNextDesignTokens

/// DEV and NIGHTLY (Debug: Toast Playground): the themes the gallery's light and dark sheets draw in, the
/// galleries' Soft Blue pair, so a playground shot compares with the other galleries'. A missing theme
/// leaves its sheet in the window's own theme.
///
/// ```swift
/// let themes = CmuxToastPlaygroundThemes(colors: catalog.colors) // ThemeCatalog's files by name
/// ```
public struct CmuxToastPlaygroundThemes {
    static let lightName = "Soft Blue Light"
    static let darkName = "Soft Blue"
    private var inputs: [Bool: ThemeInput] = [:]

    /// Picks the light and dark sheets' themes from `colors`.
    /// - Parameter colors: Theme files' colors by theme name (the app's theme catalog).
    public init(colors: [String: ThemeFileColors]) {
        for (isDark, name) in [(false, Self.lightName), (true, Self.darkName)] {
            guard let file = colors[name] else { continue }
            var input = ThemeInput(background: file.background, foreground: file.foreground, palette: file.palette.compactMap { $0 },
                                   selectionBackground: file.selectionBackground, selectionForeground: file.selectionForeground)
            input.accentColor = file.accent
            inputs[isDark] = input
        }
    }

    /// The light or dark sheet's theme name and colors; nil when its file was not found.
    func theme(isDark: Bool) -> (spec: ThemeSpec?, input: ThemeInput)? {
        inputs[isDark].map { (ThemeSpec(isDark ? Self.darkName : Self.lightName), $0) }
    }
}
