import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

/// The R114 gate wired into the updater service (SIDEBAR-FOOTER-MINIMAL):
/// the footer pill shows only a staged update, a click installs at once
/// (running agents never hold it: the relaunch keeps them), and a quit
/// honors `updates.installOnQuit`.
@MainActor
@Suite struct UpdaterServiceFlowTests {
    private final class Calls {
        var installs = 0
        var cancels = 0
    }

    private func service() -> (UpdaterService, Calls) {
        let defaults = UserDefaults(suiteName: "cmux-next-updater-flow-\(UUID().uuidString)")!
        let service = UpdaterService(identity: AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: "100"),
                                     policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false)
        let calls = Calls()
        service.installStaged = { calls.installs += 1 }
        service.cancelStaged = { calls.cancels += 1 }
        return (service, calls)
    }

    @Test func aDownloadShowsNoPillAndNoCard() {
        let (service, _) = service()
        service.debugIndicatorPhase = .downloading(progress: 0.5)
        #expect(service.footerPill == nil)
        #expect(service.card == nil)
    }

    @Test func aStagedUpdateShowsThePillAndNoCard() {
        let (service, _) = service()
        service.debugIndicatorPhase = .ready(version: "1.0.0-nightly.7")
        #expect(service.footerPill == .ready)
        #expect(service.card == nil)
    }

    /// The pill's click installs at once, with no question and no wait.
    @Test func aClickOnThePillInstallsAtOnce() {
        let (service, calls) = service()
        service.debugIndicatorPhase = .ready(version: "2")
        service.installClicked()
        #expect(calls.installs == 1)
        #expect(service.card == nil)
    }

    /// Sparkle's relaunch hook asks the App to quit keeping sessions (the
    /// App records `.explicit(.keep)`; DebugUpdaterTests checks the quit).
    @Test func theRelaunchAsksForAKeepSessionsQuit() {
        let (service, _) = service()
        var relaunches = 0
        service.willRelaunch = { relaunches += 1 }
        service.updaterWillRelaunchApplication()
        #expect(relaunches == 1)
    }

    @Test func aQuitCancelsThePendingInstallOnlyWhenInstallOnQuitIsOff() {
        let (service, calls) = service()
        service.debugIndicatorPhase = .ready(version: "2")
        #expect(service.prepareForQuit() == .proceed)
        #expect(calls.cancels == 0)
        service.preferences.installOnQuit = false
        #expect(service.prepareForQuit() == .cancelPendingInstall)
        #expect(calls.cancels == 1)
    }

    /// Scripts (update-e2e, `cmux update status`) read the card and the
    /// pill's label ("badge") from the status.
    @Test func statusCarriesTheCardAndThePill() {
        let (service, _) = service()
        #expect(service.status.card == nil)
        #expect(service.status.badge == nil)
        service.debugIndicatorPhase = .ready(version: "2")
        #expect(service.status.card == nil)
        #expect(service.status.badge == UpdaterStrings.readyToInstall)
    }
}
