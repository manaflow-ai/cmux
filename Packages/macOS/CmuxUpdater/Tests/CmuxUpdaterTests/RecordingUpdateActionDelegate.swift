@testable import CmuxUpdater

@MainActor
final class RecordingUpdateActionDelegate: UpdateActionDelegate {
    private(set) var retryRequestCount = 0
    private(set) var willRelaunchCount = 0

    func updaterRequestsRetryCheckForUpdates() {
        retryRequestCount += 1
    }

    func updaterWillRelaunchApplication() {
        willRelaunchCount += 1
    }
}
