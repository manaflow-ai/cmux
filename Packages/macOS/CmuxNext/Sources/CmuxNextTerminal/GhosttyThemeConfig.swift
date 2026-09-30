public import AppKit
import GhosttyKit

/// The user's Ghostty config with one theme applied (`theme = <name>` after
/// the config files, like `appearance.theme`), for a terminal whose room,
/// workspace or own theme differs from the config. Colors the config sets
/// explicitly still win, as in Ghostty. Owns its finalized config.
public final class GhosttyThemeConfig {
    let config: ghostty_config_t
    /// The theme file name.
    public let themeName: String
    /// Colors of this config, for the chrome around the terminal.
    public let colors: GhosttyThemeColors?

    init(config: ghostty_config_t, themeName: String, colors: GhosttyThemeColors?) {
        self.config = config
        self.themeName = themeName
        self.colors = colors
    }

    isolated deinit {
        ghostty_config_free(config)
    }
}

extension GhosttyRuntime {
    /// The user's config with theme `name` applied. Built once per name
    /// (it reads the config files) and reused until the next config
    /// change. Nil when libghostty is unavailable or `name` could inject
    /// another config line.
    public func themeConfig(named name: String) -> GhosttyThemeConfig? {
        if let cached = themeConfigs[name] { return cached }
        guard app != nil, Self.themeOverrideLine(name) != nil else { return nil }
        var diagnostics: [String] = []
        var opacity: Double = 1
        guard let config = Self.loadConfig(diagnostics: &diagnostics, opacity: &opacity, theme: name) else { return nil }
        let themed = GhosttyThemeConfig(config: config, themeName: name,
                                        colors: Self.themeColors(of: config, backgroundOpacity: opacity))
        themeConfigs[name] = themed
        return themed
    }
}
