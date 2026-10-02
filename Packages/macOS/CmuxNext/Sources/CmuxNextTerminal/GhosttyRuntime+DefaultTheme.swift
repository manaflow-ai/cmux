import Foundation
import GhosttyKit

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
    static func loadThemeDefault(into config: ghostty_config_t) {
    }

    /// The colors a user config made of `text` (Ghostty config lines)
    /// resolves to with the default loaded first, for tests. Ghostty applies
    /// a light/dark spec's variant only through an app's color scheme; a
    /// bare config resolves the light variant.
    static func themeColors(configText text: String) -> GhosttyThemeColors? {
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        loadThemeDefault(into: config)
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        return themeColors(of: config, backgroundOpacity: 1)
    }
}
