import Foundation
@testable import CmuxUpdater

@MainActor
struct Harness {
    let updater: FakeUpdater
    let clock: TestDeadlineClock
    let controller: UpdateController
    var model: UpdateStateModel { controller.model }

    init() {
        let suiteName = "cmux.updater.pipeline-tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let updater = FakeUpdater()
        let clock = TestDeadlineClock()
        self.updater = updater
        self.clock = clock
        self.controller = UpdateController(
            log: NoopUpdateLog(),
            clock: clock,
            defaults: defaults,
            isDevLikeBundle: false,
            updaterFactory: { _, _ in updater }
        )
    }
}
