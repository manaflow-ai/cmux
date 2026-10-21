@preconcurrency import Sparkle

/// The `SPUUpdater` the controller builds. With background installs on (cmux-next), Sparkle's
/// own silent driver never runs, whatever `SUAutomaticallyUpdate` says.
///
/// Sparkle picks its silent driver for a scheduled check only when `automaticallyDownloadsUpdates`
/// is true (`SPUUpdater.m`, `_checkForUpdatesInBackground`, Sparkle 2.10). That driver downloads,
/// then hands over nothing but an install-now block (`willInstallUpdateOnQuit`); while the update
/// waits, every later check resumes it instead of reading the feed, so a newer build can never
/// replace it (2026-10-21: one nightly waited 12 hours while about 25 newer ones shipped). It also
/// skips this app's driver, so the rollback skip, the pending-delta wait and the metered-network
/// policy never apply. Background installs already download every found update through this
/// app's driver (``UpdateController/downloadsUpdatesInBackground``), so the key adds nothing there.
///
/// Only the getter Sparkle reads is overridden: nothing is written to defaults. The legacy NIGHTLY
/// app shares this defaults domain and keeps its own `SUAutomaticallyUpdate` behavior, and
/// prompt-driven hosts (background installs off) read the key as before.
final class CmuxSPUUpdater: SPUUpdater {
    /// The controller's driver (set once, right after init).
    weak var hostDriver: UpdateDriver?

    override var automaticallyDownloadsUpdates: Bool {
        get { hostDriver?.installsInBackground == true ? false : super.automaticallyDownloadsUpdates }
        set { super.automaticallyDownloadsUpdates = newValue }
    }
}
