import CmuxNextBrowser

/// Cleanup the launch defers until it settles (`LaunchSettle`): it must
/// not compete with the first window and its first terminal frame.
///
/// The work is injected, so the launch hook is tested without the app:
/// `AppDelegate` takes the default (the real cleanup), and a test passes
/// its own closure and settles a `LaunchSettle` itself.
struct LaunchCleanup {
    /// Deletes the temporary download files earlier runs left
    /// (`BrowserDownloadTempFiles`; it reads the record and deletes the
    /// files off the main actor, and never touches this run's downloads).
    let cleanUpDownloadTempFiles: @MainActor () -> Void

    init(cleanUpDownloadTempFiles: @escaping @MainActor () -> Void = { BrowserDownloadTempFiles.shared.cleanUpLeftovers() }) {
        self.cleanUpDownloadTempFiles = cleanUpDownloadTempFiles
    }

    /// Runs each cleanup once, when `settle` settles (at once when it has).
    func schedule(on settle: LaunchSettle) {
        settle.whenSettled(cleanUpDownloadTempFiles)
    }
}
