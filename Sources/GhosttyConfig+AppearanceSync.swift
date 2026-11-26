import AppKit

extension GhosttyConfig {
    /// Resolves the terminal color-scheme preference for an appearance-sync pass.
    ///
    /// Explicit app modes win. In system mode after launch, the application is
    /// authoritative: a pane can retain an old or overridden effectiveAppearance
    /// during reparenting and must not reverse a system appearance transition.
    /// Use the same live app appearance as chrome, rather than the possibly stale
    /// AppleInterfaceStyle defaults. If the application appearance is unavailable,
    /// use the passed appearance and then defaults. The launch guard avoids
    /// touching NSApp.effectiveAppearance before didFinishLaunching on Tahoe.
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
        if isSystemMode, isApplicationFinishedLaunching(), let liveEffectiveAppearance = liveEffectiveAppearance() {
            return (
                preference: liveEffectiveAppearance.cmuxPrefersDark ? .dark : .light,
                source: "liveEffectiveAppearance"
            )
        }
        if isSystemMode, let passedAppearance {
            return (
                preference: passedAppearance.cmuxPrefersDark ? .dark : .light,
                source: "passedAppearance"
            )
        }
        return (
            preference: currentColorSchemePreference(defaults: defaults),
            source: "currentPreference"
        )
    }
}
