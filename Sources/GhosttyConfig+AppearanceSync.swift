import AppKit

extension GhosttyConfig {
    /// Resolves the terminal color-scheme preference for an appearance-sync pass.
    ///
    /// `passedAppearance` comes from AppKit's live appearance cascade (a view's
    /// `effectiveAppearance`, or an explicit app-level override). On scripted
    /// OS appearance changes (e.g. Shortcuts' "Set Appearance"), that cascade
    /// stays fresh, while this process's CFPreferences view of
    /// `AppleInterfaceStyle` (what the defaults-based resolution below reads)
    /// can remain stale on exactly that path. So when the app is following
    /// the system (`AppearanceMode.system`) and a non-nil appearance was
    /// passed in, it is the more trustworthy source and wins over the
    /// defaults-based read. Explicit light/dark modes always win over both,
    /// and a `nil` appearance (as passed by `AppearanceSettings.applyLiveMode`
    /// when steady-state in system mode) falls back to the existing
    /// defaults-based resolution unchanged.
    static func appearanceSyncColorSchemePreference(
        passedAppearance: NSAppearance?
    ) -> (preference: ColorSchemePreference, usedPassedAppearance: Bool) {
        let isSystemMode = AppearanceSettings.mode(
            for: UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
        ) == .system
        let usedPassedAppearance = isSystemMode && passedAppearance != nil
        let currentColorScheme: ColorSchemePreference
        if isSystemMode, let passedAppearance {
            currentColorScheme = passedAppearance.cmuxPrefersDark ? .dark : .light
        } else {
            currentColorScheme = currentColorSchemePreference()
        }
        return (preference: currentColorScheme, usedPassedAppearance: usedPassedAppearance)
    }
}
