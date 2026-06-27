@testable import CmuxUpdater

@MainActor
final class RecordingUpdateActionDelegate: UpdateActionDelegate {
    private(set) var retryRequestCount = 0
    private(set) var retryPreserveInstallIntentValues: [Bool] = []
    private(set) var willRelaunchCount = 0

    func updaterRequestsRetryCheckForUpdates(preservingInstallIntent: Bool) {
        retryRequestCount += 1
        retryPreserveInstallIntentValues.append(preservingInstallIntent)
    }

    func updaterWillRelaunchApplication() {
        willRelaunchCount += 1
    }
}
