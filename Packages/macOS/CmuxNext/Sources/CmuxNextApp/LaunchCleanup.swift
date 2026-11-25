import CmuxNextBrowser
import CmuxNextMacScreen
import CmuxNextPhoneAccess

/// Cleanup the launch defers until it settles (`LaunchSettle`): it must
/// not compete with the first window and its first terminal frame.
///
/// The work is injected, so the launch hook is tested without the app:
/// `AppDelegate` takes the default (the real cleanup), and a test passes
/// its own closures and settles a `LaunchSettle` itself.
struct LaunchCleanup {
    /// In order: the temporary download files earlier runs left (`BrowserDownloadTempFiles`, off the
    /// main actor, never this run's downloads), then the removed Phone Access listener's own leftover
    /// (`PhoneAccessLeftovers`, off the main actor), then the Privacy & Security rows of retired
    /// helpers (`RetiredPermissionRows`, once per app version, off the main actor).
    var jobs: [@MainActor () -> Void] = [{ BrowserDownloadTempFiles.shared.cleanUpLeftovers() },
                                          { _ = PhoneAccessLeftovers().cleanUpInBackground() }, { _ = RetiredPermissionRows().cleanUpInBackground() }]

    /// Runs each cleanup once, when `settle` settles (at once when it has).
    func schedule(on settle: LaunchSettle) {
        for job in jobs { settle.whenSettled(job) }
    }
}
