import Foundation
@testable import CmuxUpdater

@MainActor
final class FakeUpdater: UpdaterHandle {
    private(set) var checkForUpdatesCallCount = 0
    var canCheckForUpdates = true
    // False so the controller skips the background launch probe in tests.
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var updateCheckInterval: TimeInterval = 3600

    func start() throws {}

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

    func checkForUpdateInformation() {}
}
