public import AppKit
import GhosttyNextKit

/// The user's Ghostty config with one theme applied (`theme = <name>` after
/// the config files, like `appearance.theme`), for a terminal whose room,
/// workspace or own theme differs from the config. Colors the config sets
/// explicitly still win, as in Ghostty. Owns its finalized config.
@MainActor
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

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            ghostty_config_free(config)
        }
    }
}

extension GhosttyRuntime {
    /// The user's config with theme `name` applied, built once per name and
    /// reused until the next config change. The build reads the config
    /// files, so it runs on the config loader: the first ask returns nil and
    /// starts it, and the handlers of ``addThemeConfigHandler(_:)`` run when
    /// it is cached (the owner meanwhile inherits, as for no theme). Nil also
    /// when libghostty is unavailable or `name` could inject another config
    /// line.
    public func themeConfig(named name: String) -> GhosttyThemeConfig? {
        guard app != nil, Self.themeOverrideLine(name) != nil, let configLoader else { return nil }
        return themeConfigs.config(named: name, loader: configLoader) { GhosttyConfigInputs.current(theme: name) }
    }

    /// Runs `handler` each time a theme config ``themeConfig(named:)`` asked for lands and is cached: an owner
    /// that got nil resolves again and gets it.
    public func addThemeConfigHandler(_ handler: @escaping @MainActor () -> Void) {
        themeConfigs.addHandler(handler)
    }
}
