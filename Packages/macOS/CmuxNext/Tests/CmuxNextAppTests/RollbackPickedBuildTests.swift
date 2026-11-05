@testable import CmuxNextUpdater
import Foundation
import Testing

/// After a rollback or Install this version, the build the person picked is remembered: while it
/// runs a newer build waits for their click (UpdateController.asksBeforeInstalling, its own test in
/// CmuxUpdater's BackgroundInstallTests); once another build runs, the hold is gone for good.
@MainActor @Suite struct RollbackPickedBuildTests {
    @Test func theHoldStaysWhileThePickedBuildRunsAndGoesOnceAnotherDoes() async throws {
        let h = TipUpdateCheckTests.make()
        h.updater.defaults.set(h.updater.identity.build, forKey: UpdaterService.pickedBuildKey)
        h.updater.restoreRollbackSkip()
        #expect(h.updater.defaults.string(forKey: UpdaterService.pickedBuildKey) == h.updater.identity.build)

        h.updater.defaults.set("77", forKey: UpdaterService.pickedBuildKey)
        h.updater.restoreRollbackSkip()
        #expect(h.updater.defaults.string(forKey: UpdaterService.pickedBuildKey) == nil)
    }
}
