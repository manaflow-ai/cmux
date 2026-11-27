import Foundation
@testable import CmuxUpdaterTestSupport
@testable import CmuxUpdater

@MainActor
struct Harness {
    let updater: FakeUpdater
    let clock: TestDeadlineClock
    let controller: UpdateController
    let defaults: UserDefaults
    let suiteName: String
    var model: UpdateStateModel { controller.model }

    init(automaticDownloads: Bool = false) {
        let suiteName = "cmux.updater.pipeline-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        // The pipeline tests exercise an explicit host choice. Mark the migration complete so
        // the shared updater default does not turn an intentional notify-only fixture back on.
        defaults.set(automaticDownloads, forKey: UpdateSettings.automaticallyUpdateKey)
        defaults.set(true, forKey: UpdateSettings.automaticInstallMigrationKey)
        let updater = FakeUpdater()
        let clock = TestDeadlineClock()
        self.updater = updater
        self.clock = clock
        self.defaults = defaults
        self.suiteName = suiteName
        self.controller = UpdateController(
            log: NoopUpdateLog(),
            clock: clock,
            defaults: defaults,
            isDevLikeBundle: false,
            updaterFactory: { _, _ in updater }
        )
    }

    func finishSparkleCycle(error: (any Error)? = nil) {
        updater.sessionInProgress = false
        controller.driver.handleDidFinishUpdateCycle(.updates, error: error)
    }
}
