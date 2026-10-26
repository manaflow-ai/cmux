public import AppKit
import GhosttyNextKit

/// The user's Ghostty config with one theme applied (`theme = <name>` after
/// the config files, like `appearance.theme`), for a terminal whose room,
/// workspace or own theme differs from the config. Colors the config sets
/// explicitly still win, as in Ghostty. Owns its finalized config.
@MainActor
public final class GhosttyThemeConfig {
    /// SAFETY: owned by this object from `init` and freed once, in `deinit`; readers use it
    /// while they hold the object.
    @safe let config: ghostty_config_t
    /// The theme file name.
    public let themeName: String
    /// Colors of this config, for the chrome around the terminal.
    public let colors: GhosttyThemeColors?

    /// Takes over `config`, a live handle no one else frees.
    init(config: ghostty_config_t, themeName: String, colors: GhosttyThemeColors?) {
        self.config = unsafe config
        self.themeName = themeName
        self.colors = colors
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            // SAFETY: the owned config (above), freed once; no reader outlives this object.
            unsafe ghostty_config_free(config)
        }
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
        // SAFETY: loadConfig returns a new live config; GhosttyThemeConfig takes it over.
        guard let config = unsafe Self.loadConfig(diagnostics: &diagnostics, opacity: &opacity, theme: name) else { return nil }
        // SAFETY: as above.
        let themed = unsafe GhosttyThemeConfig(config: config, themeName: name,
                                               colors: Self.themeColors(of: config, backgroundOpacity: opacity))
        themeConfigs[name] = themed
        return themed
    }
}
