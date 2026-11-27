public import Foundation
import CmuxUpdater

/// The automatic updater's pause (``UpdaterService/pausesAutomaticUpdates``). Leo, 2026-11-24: "so pasuse the
/// auto updateer for now". While it holds, cmux NEXT checks, downloads and installs only on the person's click
/// (Check for Updates, Update, Restart to Update); `updates.checkAutomatically`, `updates.downloadAutomatically`
/// and `updates.installWhenIdle` keep their values and apply again once this is false.
public struct AutomaticUpdatePause {
    public init() {}
    /// The app's updater (AppServices), except in a restart loop, which still fetches its fix (LaunchRecovery).
    /// Tests build theirs unpaused unless they pass it.
    /// Off again (Lawrence, 2026-11-25: "automatic updates is broken fix"; Leo, 2026-11-27: "it was supposed to
    /// be a temp thing"): while paused the card's switch could not turn on.
    public static let app = false

    /// Marks a shared Sparkle value written by the temporary pause.
    public static let appliedKey = "cmux.next.automaticUpdatePause.applied.v2"
    /// Whether the pause replaced a persisted shared value.
    public static let previousValuePresentKey = "cmux.next.automaticUpdatePause.previousValuePresent.v2"
    /// The shared Sparkle value that the pause replaced.
    public static let previousValueKey = "cmux.next.automaticUpdatePause.previousValue.v2"

    /// Applies the pause or the resolved NEXT setting before Sparkle is constructed. The return value records a
    /// pre-existing shared opt-out, which remains authoritative for this launch and for later settings updates.
    @discardableResult
    public static func prepare(in defaults: UserDefaults, resolvedAutomaticChecks: Bool?, paused: Bool) -> Bool {
        let wasApplied = defaults.bool(forKey: appliedKey)
        let previousPresent = defaults.bool(forKey: previousValuePresentKey)
        let previousValue = defaults.bool(forKey: previousValueKey)
        let sharedOptOut: Bool
        if wasApplied {
            sharedOptOut = previousPresent && !previousValue
        } else {
            sharedOptOut = defaults.object(forKey: UpdateSettings.automaticChecksKey) != nil
                && !defaults.bool(forKey: UpdateSettings.automaticChecksKey)
        }

        if paused {
            if !wasApplied {
                if let value = defaults.object(forKey: UpdateSettings.automaticChecksKey) {
                    defaults.set(true, forKey: previousValuePresentKey)
                    defaults.set((value as? NSNumber)?.boolValue ?? defaults.bool(forKey: UpdateSettings.automaticChecksKey),
                                 forKey: previousValueKey)
                } else {
                    defaults.set(false, forKey: previousValuePresentKey)
                    defaults.removeObject(forKey: previousValueKey)
                }
                defaults.set(true, forKey: appliedKey)
            }
            defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
            return sharedOptOut
        }

        if wasApplied {
            if previousPresent {
                defaults.set(previousValue, forKey: UpdateSettings.automaticChecksKey)
            } else {
                defaults.removeObject(forKey: UpdateSettings.automaticChecksKey)
            }
            defaults.removeObject(forKey: appliedKey)
            defaults.removeObject(forKey: previousValuePresentKey)
            defaults.removeObject(forKey: previousValueKey)
        }
        if let resolvedAutomaticChecks {
            defaults.set(resolvedAutomaticChecks && !sharedOptOut, forKey: UpdateSettings.automaticChecksKey)
        }
        return sharedOptOut
    }
}
