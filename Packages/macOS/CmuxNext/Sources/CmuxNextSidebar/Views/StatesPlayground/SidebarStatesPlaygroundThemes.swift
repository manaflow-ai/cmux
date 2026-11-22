public import CmuxNextDesign

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): the terminal themes the light and dark sheets draw in.
///
/// The sheets use the galleries' pair, Soft Blue Light and Soft Blue, so a playground shot and a gallery shot
/// compare. A missing theme leaves its sheet in the window's own theme, in that sheet's appearance.
///
/// ```swift
/// let themes = SidebarStatesPlaygroundThemes(colors: catalog.colors) // ThemeCatalog's files by name
/// ```
public struct SidebarStatesPlaygroundThemes {
    /// The light sheet's theme name.
    static let lightName = "Soft Blue Light"
    /// The dark sheet's theme name.
    static let darkName = "Soft Blue"

    private var inputs: [SidebarStatesPlaygroundAppearance: ThemeInput] = [:]

    /// Picks the light and dark sheets' themes from `colors`.
    /// - Parameter colors: Theme files' colors by theme name (the app's theme catalog, or files a test read).
    public init(colors: [String: ThemeFileColors]) {
        for (appearance, name) in [(SidebarStatesPlaygroundAppearance.light, Self.lightName), (.dark, Self.darkName)] {
            guard let file = colors[name] else { continue }
            var input = ThemeInput(background: file.background, foreground: file.foreground, palette: file.palette.compactMap { $0 },
                                   selectionBackground: file.selectionBackground, selectionForeground: file.selectionForeground)
            input.accentColor = file.accent
            inputs[appearance] = input
        }
    }

    /// The theme name and colors of `appearance`'s sheet; nil when its file was not found.
    func theme(_ appearance: SidebarStatesPlaygroundAppearance) -> (spec: ThemeSpec?, input: ThemeInput)? {
        inputs[appearance].map { (ThemeSpec(appearance == .dark ? Self.darkName : Self.lightName), $0) }
    }
}
