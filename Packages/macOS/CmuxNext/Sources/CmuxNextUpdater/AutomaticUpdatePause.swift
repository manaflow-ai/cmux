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

    /// Set once ``resumeAutomaticChecks(in:)`` ran on these defaults.
    public static let resumedKey = "cmux.next.automaticUpdatePause.resumedChecks.v1"

    /// Every paused launch wrote `SUEnableAutomaticChecks = false`, which Sparkle reads at start for its launch
    /// check and schedule, before ``UpdaterService/configure`` applies `updates.checkAutomatically`. The first
    /// unpaused launch removes that `false` once (Sparkle's registered default, on, applies until the person's
    /// setting is written back), so a Mac that ran a paused build checks again by itself.
    public static func resumeAutomaticChecks(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: resumedKey) else { return }
        if defaults.object(forKey: UpdateSettings.automaticChecksKey) != nil, !defaults.bool(forKey: UpdateSettings.automaticChecksKey) {
            defaults.removeObject(forKey: UpdateSettings.automaticChecksKey)
        }
        defaults.set(true, forKey: resumedKey)
    }
}
