public import CmuxNextWakeups

/// Cleanup the launch defers until startup completes: it must not compete
/// with the first window and its first terminal frame. An afterStartup post
/// of the launch's ``StartupScheduler`` (Chrome's `AfterStartupTaskUtils::PostTask`,
/// chrome/browser/after_startup_task_utils.cc).
///
/// The work is injected, so the launch hook is tested without the app:
/// `AppDelegate` passes the real cleanup, and a test passes its own
/// closure and completes its own scheduler.
public struct LaunchCleanup {
    /// Deletes the temporary download files earlier runs left
    /// (`BrowserDownloadTempFiles`). On main it only queues the cleanup: the
    /// record is read and the files deleted on the record's own actor, off
    /// main and in order with this run's downloads, which it never touches.
    let cleanUpDownloadTempFiles: @MainActor @Sendable () -> Void

    public init(cleanUpDownloadTempFiles: @escaping @MainActor @Sendable () -> Void) {
        self.cleanUpDownloadTempFiles = cleanUpDownloadTempFiles
    }

    /// Posts each cleanup to run once, after startup completes.
    public func schedule(on startup: StartupScheduler) {
        startup.post(.afterStartup, "LaunchCleanup.downloadTempFiles", on: .main, cleanUpDownloadTempFiles)
    }
}
