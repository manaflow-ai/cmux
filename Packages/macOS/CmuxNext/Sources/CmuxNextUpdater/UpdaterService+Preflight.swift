import CmuxUpdater
import Foundation

/// The checks before the install click hands the app to Sparkle's installer
/// (cx-ncc.45.7): a failure stays in this app as the update error with
/// Download Manually, instead of a quit that never comes back.
extension UpdaterService {
    /// The first failed check for the staged update, or nil.
    func installPreflightFailure() -> UpdateInstallPreflight.Failure? {
        let bytes = controller?.stagedUpdate.map { Int64(clamping: $0.contentLength) }
        let preflight = UpdateInstallPreflight(bundle: Bundle.main.bundleURL, updateBytes: bytes.flatMap { $0 > 0 ? $0 : nil },
                                               stagedInstallation: UpdateInstallPreflight.stagedInstallation(bundleIdentifier: Bundle.main.bundleIdentifier))
        // concurrency-allow: two access checks, one volume read and two directory reads, at the click, before the app quits.
        let failure = preflight.failure()
        // concurrency-allow: one directory existence check, same click.
        if failure == nil, !preflight.knowsStagedLayout() {
            log.append("install preflight: Sparkle's staging folder is not where 2.9.5 kept it; the staged-update check let the click through")
        }
        return failure
    }

    /// Fails the install in place: the update error says why and offers the
    /// manual download; nothing quits.
    func failInstall(_ failure: UpdateInstallPreflight.Failure) {
        log.append("install preflight failed: \(failure)")
        controller?.failStagedInstall(message: UpdateInstallPreflight.message(failure), diagnostic: "install preflight: \(failure)")
    }
}
