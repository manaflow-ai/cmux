public import Foundation
@preconcurrency import Sparkle

/// The slice of `SPUUpdater` that ``UpdateController`` drives.
///
/// A seam, not an abstraction: production always passes a real `SPUUpdater`. It exists so the
/// controller's reaction pipeline (attempt coordinator, install watchdog, prompt dismissal)
/// can be driven deterministically in tests by a fake — the real Sparkle install path only runs
/// in release-channel builds, so pipeline regressions like the NIGHTLY double-idle install loop
/// (https://github.com/manaflow-ai/cmux/pull/7174) are otherwise invisible until a nightly ships.
@MainActor
protocol UpdaterHandle: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get }
    var automaticallyDownloadsUpdates: Bool { get }
    var updateCheckInterval: TimeInterval { get }
    func start() throws
    func checkForUpdates()
    func checkForUpdateInformation()
}

extension SPUUpdater: UpdaterHandle {}
