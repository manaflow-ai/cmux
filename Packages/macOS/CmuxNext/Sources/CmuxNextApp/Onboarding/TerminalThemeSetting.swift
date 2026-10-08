import Foundation
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTerminal
import Observation

/// cmux's own terminal look in cmux.json, written by onboarding:
/// `appearance.theme` (a Ghostty theme, or `light:A,dark:B`) and
/// `terminal.fontFamily` / `terminal.fontSize`, plus the window background
/// (`appearance.backgroundOpacity`, `appearance.backgroundBlur`). Applied
/// as Ghostty overrides (`GhosttyRuntime.themeOverride`, `fontOverride`,
/// `backgroundOverride`) and a config reload, so terminals and chrome
/// follow live. The Ghostty config file itself never changes.
@MainActor
final class TerminalThemeSetting {
    static let path = AppThemeSetting().configPath
    static let fontFamilyPath = TerminalFontSetting().familyPath
    static let fontSizePath = TerminalFontSetting().sizePath

    private struct State: Equatable {
        var theme: String?
        var font: GhosttyRuntime.FontOverride
        var background: WindowBackgroundOverride
        /// `appearance.surfaces.terminal` is set: surfaces draw a
        /// transparent default background (`GhosttyRuntimeSurfacePolicy`).
        var terminalOverridden = false

        init(theme: String?, font: GhosttyRuntime.FontOverride, background: WindowBackgroundOverride, terminalOverridden: Bool = false) {
            (self.theme, self.font, self.background, self.terminalOverridden) = (theme, font, background, terminalOverridden)
        }

        /// Parsed and validated in `CmuxConfigSnapshot` (a bad value is a
        /// diagnostic and keeps the Ghostty config's).
        init(_ snapshot: CmuxConfigSnapshot) {
            self.init(theme: snapshot.appTheme,
                      font: GhosttyRuntime.FontOverride(family: snapshot.terminalFontFamily, size: snapshot.terminalFontSize),
                      background: snapshot.windowBackground, terminalOverridden: snapshot.surfaceBackgrounds.overridesTerminal)
        }
    }

    /// What the runtime's first config load had (`prime`); taken by the
    /// first apply, which skips the reload when it matches.
    private static var primed: State?

    private let backdropScope: ThemeScope

    init(backdropScope: ThemeScope) {
        self.backdropScope = backdropScope
    }

    private var applied: State?
    /// Reloads the Ghostty config with the overrides (tests count it).
    var reload: () -> Void = { GhosttyRuntime.shared.reloadConfig() }
    private var observation: Task<Void, Never>?

    /// Applies the loaded settings at once (launch loads them before the
    /// first window, which must not draw a frame in the defaults), then
    /// follows their changes.
    func follow(_ settings: SettingsController) {
        take(settings.snapshot)
        observation = Task { [weak self] in
            for await snapshot in Observations({ settings.snapshot }) { self?.take(snapshot) }
        }
    }

    private func take(_ snapshot: CmuxConfigSnapshot) {
        backdropScope.setBackdropSelection(snapshot.backdropSelection)
        backdropScope.setAppearanceTuning(snapshot.experimentalAppearance ? snapshot.appearanceTuning : .identity)
        // Per-surface backgrounds (R55): every owner repaints from them.
        backdropScope.setSurfaceBackgrounds(snapshot.surfaceBackgrounds)
        apply(State(snapshot))
    }

    /// Puts `snapshot`'s appearance on the Ghostty overrides before the
    /// runtime starts, so its first config load already has them.
    static func prime(_ snapshot: CmuxConfigSnapshot) {
        let state = State(snapshot)
        primed = state
        set(state)
    }

    /// The review tool's light/dark preview: Ghostty's Apple System Colors
    /// (dark) or Apple System Colors Light, in memory only (nil: back to the
    /// configured theme). Never writes cmux.json.
    func preview(dark: Bool?) {
        GhosttyRuntime.themeOverride = dark.map { $0 ? GhosttyRuntime.defaultDarkThemeName : GhosttyRuntime.defaultLightThemeName } ?? applied?.theme
        GhosttyRuntime.shared.reloadConfig()
    }

    private func apply(_ state: State) {
        guard applied != state else { return }
        let first = applied == nil
        applied = state
        Self.set(state)
        guard first else { return reload() }
        // At launch the config already loaded with these overrides (primed) or none.
        let loaded = Self.primed ?? State(theme: nil, font: .init(), background: .init())
        Self.primed = nil
        if state != loaded { reload() }
    }

    private static func set(_ state: State) {
        GhosttyRuntime.themeOverride = state.theme
        GhosttyRuntime.fontOverride = state.font
        let family = state.font.family?.trimmingCharacters(in: .whitespaces) ?? ""
        DesignSettings.shared.terminalFontFamily = family.isEmpty ? nil : family
        GhosttyRuntime.backgroundOverride = state.background
        GhosttyRuntime.terminalBackgroundOverridden = state.terminalOverridden
    }
}
