import AppKit
import CmuxNextDesign
import CmuxNextTerminal
import CmuxNextWakeups
import Observation

/// Turns a theme spec (room, workspace or terminal) into colors for the
/// chrome and a Ghostty config for the surfaces, resolved like the global
/// config: the user's config files, then `theme = <name>`, so colors the
/// config sets explicitly (and its opacity and blur) still win. A light/dark
/// pair resolves to the variant for the current system appearance.
///
/// Configs are built once per theme name by `GhosttyRuntime` and dropped on
/// every config change; `generation` bumps then and on a light/dark switch,
/// so owners re-resolve. ``isDark`` is observable (Settings' light/dark pair side follows it).
@MainActor
@Observable
final class ThemeResolver {
    struct Resolved {
        let spec: ThemeSpec
        let input: ThemeInput
        let config: GhosttyThemeConfig
    }

    /// Bumps when resolved colors may have changed for the same spec.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored var onChange: (() -> Void)?
    /// The Mac's light or dark (`NSApp.effectiveAppearance`), never a window's: windows take their
    /// theme's appearance, and the side of a light/dark pair follows the system.
    private(set) var isDark: Bool
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    init() {
        isDark = Self.systemIsDark()
        // KVO calls back on the changing thread: inline on main, a hop from anywhere else.
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { @Sendable [weak self] _, _ in
            MainDelivery().run { self?.appearanceDidChange() }
        }
        let runtime = GhosttyRuntime.shared
        let previous = runtime.onConfigChange
        runtime.onConfigChange = { [weak self] in
            previous?()
            self?.changed()
        }
    }

    /// Colors and config for `spec`; nil for no spec, or when libghostty
    /// cannot build a config (the level then inherits).
    func resolve(_ spec: ThemeSpec?) -> Resolved? {
        guard let spec, case let name = spec.name(isDark: isDark), let config = GhosttyRuntime.shared.themeConfig(named: name),
              let colors = config.colors else { return nil }
        let input = ThemeBridge.input(colors, background: GhosttyRuntime.backgroundOverride, accent: ThemeBridge.accent(name))
        return Resolved(spec: spec, input: input, config: config)
    }

    /// Colors for the App Theme (`appearance.appTheme`): `spec`'s theme file with the person's edits,
    /// never the Ghostty config's own color lines (they stay the terminals'), with the window's
    /// opacity and blur as `resolve` gives them. Cached per theme name until the next config change.
    func resolveAppTheme(_ spec: ThemeSpec?) -> ThemeInput? {
        guard let resolved = resolve(spec) else { return nil }
        let name = resolved.config.themeName
        let colors: GhosttyThemeColors?
        if let cached = appThemeColors[name], cached.generation == generation {
            colors = cached.colors
        } else {
            colors = GhosttyRuntime.appThemeColors(theme: name, edits: GhosttyRuntime.themeEdits)
            appThemeColors[name] = (generation, colors)
        }
        guard var colors else { return resolved.input }
        colors.backgroundOpacity = resolved.config.colors?.backgroundOpacity ?? colors.backgroundOpacity
        colors.backgroundBlur = resolved.config.colors?.backgroundBlur ?? colors.backgroundBlur
        return ThemeBridge.input(colors, background: GhosttyRuntime.backgroundOverride, accent: ThemeBridge.accent(name))
    }

    @ObservationIgnored private var appThemeColors: [String: (generation: Int, colors: GhosttyThemeColors?)] = [:]

    private func appearanceDidChange() {
        let dark = Self.systemIsDark()
        guard dark != isDark else { return }
        isDark = dark
        changed()
    }

    /// Re-resolves every level (a theme's accent changed, which no config reload reports).
    func changed() {
        generation += 1
        onChange?()
    }

    private static func systemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
