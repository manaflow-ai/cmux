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
    /// defaults-based read. Explicit light/dark modes always win over both. A
    /// `nil` appearance still resolves through the live app effectiveAppearance
    /// after launch so later reloads cannot flip back to a stale
    /// AppleInterfaceStyle value; before launch, it falls back to the existing
    /// defaults-based resolution to avoid touching NSApp.effectiveAppearance.
    static func appearanceSyncColorSchemePreference(
        passedAppearance: NSAppearance?,
        defaults: UserDefaults = .standard,
        isApplicationFinishedLaunching: () -> Bool = AppIconLaunchState.isApplicationFinishedLaunching,
        liveEffectiveAppearance: () -> NSAppearance? = {
            guard Thread.isMainThread else { return nil }
            return NSApp?.effectiveAppearance
        }
    ) -> (preference: ColorSchemePreference, source: String) {
        let isSystemMode = AppearanceSettings.mode(
            for: defaults.string(forKey: AppearanceSettings.appearanceModeKey)
        ) == .system
        if isSystemMode, let passedAppearance {
            return (
                preference: passedAppearance.cmuxPrefersDark ? .dark : .light,
                source: "passedAppearance"
            )
        }
        if isSystemMode, isApplicationFinishedLaunching(), let liveEffectiveAppearance = liveEffectiveAppearance() {
            return (
                preference: liveEffectiveAppearance.cmuxPrefersDark ? .dark : .light,
                source: "liveEffectiveAppearance"
            )
        }
        return (
            preference: currentColorSchemePreference(defaults: defaults),
            source: "currentPreference"
        )
    }
}
