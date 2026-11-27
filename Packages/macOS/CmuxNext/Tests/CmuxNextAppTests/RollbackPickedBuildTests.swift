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

    /// Turning automatic downloads back on (the setting, a link that cleared) downloads a found
    /// update, except on the build the person picked: that one still waits for their click (#36419).
    @Test func downloadsComingOnKeepThePickedBuildsHold() {
        let updater = SilentBackgroundUpdateTests.updater()
        var accepted = 0
        updater.acceptAvailable = { accepted += 1 }
        updater.defaults.set(updater.identity.build, forKey: UpdaterService.pickedBuildKey)
        updater.downloadSetting = (true, .deferLowData)
        updater.applyDownloadPolicy()
        #expect(accepted == 0, "turning downloads on downloaded a newer build without the click the rollback asks for")
        updater.network = (constrained: true, expensive: false)
        updater.applyDownloadPolicy()
        updater.network = (constrained: false, expensive: false)
        updater.applyDownloadPolicy()
        #expect(accepted == 0, "Low Data Mode ending downloaded a newer build without the click")

        // Once another build runs the hold is gone, and the found update downloads as set.
        updater.defaults.set("77", forKey: UpdaterService.pickedBuildKey)
        updater.network = (constrained: true, expensive: false)
        updater.applyDownloadPolicy()
        updater.network = (constrained: false, expensive: false)
        updater.applyDownloadPolicy()
        #expect(accepted == 1)
    }

    /// An update the organization requires (`MinimumVersion`) still downloads on the picked build.
    @Test func aRequiredUpdateDownloadsOnThePickedBuild() {
        let updater = SilentBackgroundUpdateTests.updater()
        var accepted = 0
        updater.acceptAvailable = { accepted += 1 }
        updater.defaults.set(updater.identity.build, forKey: UpdaterService.pickedBuildKey)
        updater.applyManagedPolicy(channel: nil, minimumVersion: "9.0")
        #expect(updater.requiredMinimumVersion == "9.0")
        #expect(accepted == 1, "the rollback hold kept an update the organization requires from downloading")
    }
}
