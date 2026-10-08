import Foundation
import GhosttyNextKit

/// cmux-next's default terminal theme, which differs from Ghostty's: Ghostty's
/// bundled "Apple System Colors" in dark mode and "Apple System Colors Light"
/// in light mode, following the macOS appearance live. It is loaded before
/// the user's Ghostty config files, so their own `theme` or colors win, and
/// everyone without one gets it.
extension GhosttyRuntime {
    /// Theme file names in Ghostty's bundled `themes` folder.
    public nonisolated static let defaultDarkThemeName = "Apple System Colors"
    public nonisolated static let defaultLightThemeName = "Apple System Colors Light"

    /// The default as a Ghostty theme spec.
    public nonisolated static var defaultThemeSpec: String {
        "light:\(defaultLightThemeName),dark:\(defaultDarkThemeName)"
    }

    /// Loads the default before the user's files.
    /// `themesFolder` names the themes by absolute path (tests: Ghostty
    /// reads its resources folder once, at `ghostty_init`).
    static func loadThemeDefault(into config: ghostty_config_t, themesFolder: URL? = nil) {
        let spec = themesFolder.map { "light:\($0.appending(path: defaultLightThemeName).path),dark:\($0.appending(path: defaultDarkThemeName).path)" }
        let line = "theme = \(spec ?? defaultThemeSpec)"
        line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux-next") }
    }

    /// The colors a user config made of `text` (Ghostty config lines)
    /// resolves to with the default loaded first, for tests. Ghostty applies
    /// a light/dark spec's variant only through an app's color scheme; a
    /// bare config resolves the light variant.
    static func themeColors(configText text: String, themesFolder: URL? = nil) -> GhosttyThemeColors? {
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        loadThemeDefault(into: config, themesFolder: themesFolder)
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        return themeColors(of: config, backgroundOpacity: 1)
    }
}

extension GhosttyRuntime {
    /// Gives `view`'s new surface the current scheme and every later change.
    func registerColorScheme(of view: TerminalSurfaceView) {
        colorSchemeSurfaces.add(view)
        view.applyColorScheme(dark: isDark)
    }
}

extension TerminalSurfaceView {
    /// `ghostty_surface_set_color_scheme` (ghostty.h:1573) on the live surface.
    func applyColorScheme(dark: Bool) {
        guard let surface else { return }
        colorSchemeIsDark = dark
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }
}
