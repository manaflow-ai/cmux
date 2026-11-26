/// The automatic updater's pause (``UpdaterService/pausesAutomaticUpdates``). Leo, 2026-11-24: "so pasuse the
/// auto updateer for now". While it holds, cmux NEXT checks, downloads and installs only on the person's click
/// (Check for Updates, Update, Restart to Update); `updates.checkAutomatically`, `updates.downloadAutomatically`
/// and `updates.installWhenIdle` keep their values and apply again once this is false.
public struct AutomaticUpdatePause {
    public init() {}
    /// The app's updater (AppServices), except in a restart loop, which still fetches its fix (LaunchRecovery).
    /// Tests build theirs unpaused unless they pass it.
    /// Off again (Lawrence, 2026-11-25: "automatic updates is broken fix"): while paused the card's switch could not turn on.
    public static let app = false
}
