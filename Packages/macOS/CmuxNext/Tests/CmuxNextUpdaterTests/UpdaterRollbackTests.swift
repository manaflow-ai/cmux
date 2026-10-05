import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

/// `updates.rollback` refuses until the daemon reports its stored formats,
/// and never relaunches on a refusal.
@MainActor
@Suite struct UpdaterRollbackTests {
    @Test func refusesWhileTheDaemonCannotReportItsStores() {
        let service = UpdaterService(identity: AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: "100",
                                                                        feed: "https://files-next.cmux.com/nightly-next/appcast.xml"),
                                     policy: ManagedUpdatePolicy { false },
                                     defaults: UserDefaults(suiteName: "rollback-\(UUID().uuidString)")!, enableSparkle: false)
        var relaunched = 0
        #expect(throws: RollbackRefusal.storesUnknown) {
            try service.rollback(to: nil, stored: nil, relaunch: { _ in relaunched += 1 })
        }
        #expect(relaunched == 0)
    }
}
