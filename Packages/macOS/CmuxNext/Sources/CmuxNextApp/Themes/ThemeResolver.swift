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
/// Configs are built once per theme name by `GhosttyRuntime` and dropped on
/// every config change; `generation` bumps then and on a light/dark switch,
/// so owners re-resolve.
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
        guard let spec, let config = GhosttyRuntime.shared.themeConfig(named: spec.name(isDark: isDark)),
              let colors = config.colors else { return nil }
        return Resolved(spec: spec, input: ThemeBridge.input(colors, background: GhosttyRuntime.backgroundOverride), config: config)
    }

    private func appearanceDidChange() {
        let dark = Self.systemIsDark()
        guard dark != isDark else { return }
        isDark = dark
        changed()
    }

    private func changed() {
        generation += 1
        onChange?()
    }

    private static func systemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
