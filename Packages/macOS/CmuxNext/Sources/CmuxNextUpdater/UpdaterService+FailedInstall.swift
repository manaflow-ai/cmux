import AppKit
import CmuxNextCompat
import CmuxUpdater
import Foundation

/// An install that did not take (2026-10-21: after a relaunch, a failed install showed nothing
/// and offered "Restart to Update" again). When the previous launch of this build started
/// installing an update and the app was not replaced (``WhatsNewCenter/failedInstall``), the
/// notice card says so and why, with Try Again and Download Manually, until one of them or its x.
extension UpdaterService {
    /// The failed install's card, or nil (none, or an install is under way).
    var failedInstallCard: UpdateCard? {
        guard let record = whatsNew.failedInstall, flow.phase != .installing else { return nil }
        let reason = record.installFailure.flatMap { $0.isEmpty ? nil : $0 } ?? UpdaterStrings.installFailedReason
        return .installFailed(version: UpdateChangelog.cardVersion(record.toVersion), reason: reason)
    }

    /// Try Again: the card goes and the update installs again, the staged one (the click reads
    /// the feed for a newer one first), else the newest from a check the person sees.
    func retryFailedInstall() {
        whatsNew.dismissFailedInstall()
        syncFlowPhase()
        if case .ready = flow.phase { return send(.installRequested) }
        checkAndInstallNewest()
    }

    /// Download Manually: the channel's installer, in the default browser.
    func openManualDownload() {
        let error = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode)
        guard let url = UpdateManualDownloadRecovery().url(for: error, feedURLString: testFeedURL ?? identity.feed().url) else { return }
        log.append("install failed: opening the manual download \(url.absoluteString)")
        if let openExternalURL { return openExternalURL(url) }
        NSWorkspace.shared.openInBackground(url)
    }
}
