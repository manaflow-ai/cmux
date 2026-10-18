import Foundation
@testable import CmuxUpdater

@MainActor
final class FakeUpdater: UpdaterHandle {
    private(set) var checkForUpdatesCallCount = 0
    private var canCheckForUpdatesValue = true
    var scriptedCanCheckForUpdates: [Bool] = []
    var canCheckForUpdates: Bool {
        get {
            if !scriptedCanCheckForUpdates.isEmpty {
                return scriptedCanCheckForUpdates.removeFirst()
            }
            return canCheckForUpdatesValue
        }
        set {
            canCheckForUpdatesValue = newValue
            scriptedCanCheckForUpdates = []
        }
    }
    var sessionInProgress = false
    var startError: (any Error)?
    // False so the controller skips the background launch probe in tests.
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var updateCheckInterval: TimeInterval = 3600

    func start() throws {
        if let startError { throw startError }
    }

    func checkForUpdates() {
        sessionInProgress = true
        checkForUpdatesCallCount += 1
    }

    func checkForUpdateInformation() {}
}
