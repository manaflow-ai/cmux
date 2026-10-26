import AppKit
import CmuxNextDesign
import CmuxNextTerminal
import CmuxNextWakeups

/// Turns a theme spec (room, workspace or terminal) into colors for the
/// chrome and a Ghostty config for the surfaces, resolved like the global
/// config: the user's config files, then `theme = <name>`, so colors the
/// config sets explicitly (and its opacity and blur) still win. A light/dark
/// pair resolves to the variant for the current system appearance.
///
/// Configs are built per theme name by `GhosttyRuntime`, on a lane, and
/// rebuilt on every config change, the last one served until its rebuild
/// lands; `generation` bumps then, when a build lands and on a light/dark
/// switch, so owners re-resolve. Both sides of a pair are built, so a
/// light/dark switch finds its variant ready.
@MainActor
final class ThemeResolver {
    struct Resolved {
        let spec: ThemeSpec
        let input: ThemeInput
        let config: GhosttyThemeConfig
    }

    /// Bumps when resolved colors may have changed for the same spec.
    private(set) var generation = 0
    var onChange: (() -> Void)?
    private var isDark: Bool
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        isDark = Self.systemIsDark()
        // KVO calls back on the changing thread: inline on main, a hop from anywhere else.
        // raw-observer-allow: no notice reports a light/dark switch; KVO of NSApp's effectiveAppearance is the one source, as Chromium's NativeThemeMac observes it (ui/native_theme/native_theme_mac.mm)
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { @Sendable [weak self] _, _ in
            // main-hop-allow: AppKit changes the appearance on main, so the re-resolve runs inline in that turn, beside GhosttyRuntime's own color-scheme switch; only an off-main change hops
            MainDelivery().run { self?.appearanceDidChange() }
        }
        let runtime = GhosttyRuntime.shared
        let previous = runtime.onConfigChange
        runtime.onConfigChange = { [weak self] in
            previous?()
            self?.changed()
        }
        // A theme's config builds on a lane: a level that got nil resolves again when it lands.
        runtime.addThemeConfigHandler { [weak self] in self?.changed() }
    }

    /// Colors and config for `spec`; nil for no spec, while its first config
    /// builds, or when libghostty cannot build one (the level then inherits).
    func resolve(_ spec: ThemeSpec?) -> Resolved? {
        guard let spec else { return nil }
        let runtime = GhosttyRuntime.shared
        if spec.light != spec.dark { _ = runtime.themeConfig(named: spec.name(isDark: !isDark)) }
        guard case let name = spec.name(isDark: isDark), let config = runtime.themeConfig(named: name),
              let colors = config.colors else { return nil }
        let input = ThemeBridge.input(colors, background: GhosttyRuntime.backgroundOverride, accent: ThemeBridge.accent(name))
        return Resolved(spec: spec, input: input, config: config)
    }

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
