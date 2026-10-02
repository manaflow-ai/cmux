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
    static let path = AppThemeSetting.configPath
    static let fontFamilyPath = TerminalFontSetting.familyPath
    static let fontSizePath = TerminalFontSetting.sizePath

    private struct State: Equatable {
        var theme: String?
        var font: GhosttyRuntime.FontOverride
        var background: WindowBackgroundOverride
    }

    private var applied: State?
    private var observation: Task<Void, Never>?

    func follow(_ settings: SettingsController) {
        observation = Task { [weak self] in
            for await snapshot in Observations({ settings.snapshot }) {
                // Parsed and validated in `CmuxConfigSnapshot` (a bad value is
                // a diagnostic and keeps the Ghostty config's).
                let font = GhosttyRuntime.FontOverride(family: snapshot.terminalFontFamily, size: snapshot.terminalFontSize)
                self?.apply(State(theme: snapshot.appTheme, font: font, background: snapshot.windowBackground))
            }
        }
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
        GhosttyRuntime.themeOverride = state.theme
        GhosttyRuntime.fontOverride = state.font
        GhosttyRuntime.backgroundOverride = state.background
        // At launch with no overrides the config already loaded as is.
        if !(first && state == State(theme: nil, font: .init(), background: .init())) { GhosttyRuntime.shared.reloadConfig() }
    }
}
