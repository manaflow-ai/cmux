public import AppKit
public import CmuxNextDesign
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
    /// This theme's colors as the App Theme (`appearance.appTheme`) takes them: the theme file with the
    /// person's edits and highlight color, never the Ghostty config's own color lines (those stay the
    /// terminals'), with this config's window opacity and blur. Built on first read and dropped with
    /// this config on the next config change. Nil when libghostty cannot build it.
    public private(set) lazy var appColors: GhosttyThemeColors? = {
        guard var app = GhosttyRuntime.appThemeColors(theme: themeName, edits: GhosttyRuntime.themeEdits) else { return nil }
        if let colors { (app.backgroundOpacity, app.backgroundBlur) = (colors.backgroundOpacity, colors.backgroundBlur) }
        return app
    }()

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

    /// The colors of theme `theme` for the App Theme (`appearance.appTheme`): the theme file with the
    /// person's edits to it (`appearance.themeEdits`) and the highlight color, never the Ghostty
    /// config's own color lines, which belong to the terminals. Opacity and blur are not read here
    /// (the window's come from the full config). Nil when libghostty cannot build the config or
    /// `theme` could inject another config line.
    /// - Parameters:
    ///   - theme: A theme name or absolute path to a theme file (one variant, not a pair).
    ///   - edits: The person's theme edits and highlight color.
    public static func appThemeColors(theme: String, edits: ThemeEdits) -> GhosttyThemeColors? {
        guard themeOverrideLine(theme) != nil, let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        for line in themeLines(theme, isDark: false, edits: edits) + highlightLines(edits.highlight) {
            line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux.json") }
        }
        ghostty_config_finalize(config)
        return themeColors(of: config, backgroundOpacity: 1)
    }
}
