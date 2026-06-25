import Foundation

/// Captures, once per launch, how the previous run ended — so the rest of the app
/// can react without re-reading the filesystem and without racing the sentinel
/// (which gets overwritten by `markRunning`).
///
/// Order matters: `captureAtLaunch()` reads the unclean-shutdown sentinel and the
/// restore-intent marker BEFORE arming this run's sentinel. It must be called
/// exactly once, early in `applicationDidFinishLaunching`, before any clean-exit
/// path could fire.
@MainActor
final class CrashRecoveryLaunchState {
    /// The prior run left an unclean-shutdown sentinel (crash / kill / power loss)
    /// AND that run was not an intentional relaunch.
    private(set) var priorRunCrashed = false

    /// The prior run was an intentional relaunch (Sparkle update / Rosetta) that
    /// asked for the session to be restored.
    private(set) var restoreWasIntended = false

    private var captured = false

    init() {}

    /// Reads the prior-run markers, then arms this run's sentinel. Idempotent.
    func captureAtLaunch(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard !captured else { return }
        captured = true

        let wasUnclean = UncleanShutdownSentinel.priorRunWasUnclean(
            fileManager: fileManager, homeDirectory: homeDirectory, environment: environment
        )
        // Single-use: consuming clears the marker so a later real crash classifies
        // correctly.
        restoreWasIntended = RelaunchIntent.consumeRestoreIntent(
            fileManager: fileManager, homeDirectory: homeDirectory, environment: environment
        )
        // An intentional relaunch is never a crash, even if a sentinel lingered.
        priorRunCrashed = wasUnclean && !restoreWasIntended

        // Arm this run.
        UncleanShutdownSentinel.markRunning(
            fileManager: fileManager, homeDirectory: homeDirectory, environment: environment
        )
    }

    /// Whether the crash-recovery offer should be shown after restore: the prior
    /// run crashed AND the user opted in.
    func shouldOfferResume(defaults: UserDefaults = .standard) -> Bool {
        priorRunCrashed && CrashRecoverySettings.offerResumeAfterCrash(defaults: defaults)
    }

    /// Records a clean exit. Call on `applicationWillTerminate` and other clean
    /// shutdown paths.
    func markCleanExit(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        UncleanShutdownSentinel.markCleanExit(
            fileManager: fileManager, homeDirectory: homeDirectory, environment: environment
        )
    }

    /// Records an intentional, restore-intended relaunch (Sparkle / Rosetta): clears
    /// the sentinel and writes the restore-intent marker. Call from the relaunch hook.
    func markIntentionalRelaunch(
        reason: String,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        UncleanShutdownSentinel.markCleanExit(
            fileManager: fileManager, homeDirectory: homeDirectory, environment: environment
        )
        RelaunchIntent.markRestoreIntended(
            reason: reason, fileManager: fileManager, homeDirectory: homeDirectory, environment: environment
        )
    }
}
