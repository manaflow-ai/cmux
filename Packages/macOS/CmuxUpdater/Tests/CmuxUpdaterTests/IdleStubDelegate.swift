@testable import CmuxUpdater

@MainActor
final class IdleStubDelegate: UpdateActionDelegate {
    var isSafeToRestart = false

    func updaterRequestsRetryCheckForUpdates() {}

    func updaterWillRelaunchApplication() {}

    func updaterIsSafeToRestartNow() -> Bool { isSafeToRestart }
}
