import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

/// The R114 gate wired into the updater service: the Settings badge and
/// the card show only a staged update, a click installs, busy agents hold
/// the click, and a quit honors `updates.installOnQuit`.
@MainActor
@Suite struct UpdaterServiceFlowTests {
    private final class Calls {
        var installs = 0
        var cancels = 0
        var confirms: [UpdateBlockers] = []
    }

    private func service() -> (UpdaterService, Calls) {
        let defaults = UserDefaults(suiteName: "cmux-next-updater-flow-\(UUID().uuidString)")!
        let service = UpdaterService(identity: AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: "100"),
                                     policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false)
        let calls = Calls()
        service.installStaged = { calls.installs += 1 }
        service.cancelStaged = { calls.cancels += 1 }
        service.confirmInterrupt = { calls.confirms.append($0) }
        return (service, calls)
    }

    @Test func aDownloadShowsNoBadgeAndNoCard() {
        let (service, _) = service()
        service.debugIndicatorPhase = .downloading(progress: 0.5)
        #expect(!service.showsSettingsBadge)
        #expect(service.card == nil)
    }

    @Test func aStagedUpdateShowsTheSettingsControlAndNoCard() {
        let (service, _) = service()
        service.debugIndicatorPhase = .ready(version: "1.0.0-nightly.7")
        #expect(service.settingsBadgeTitle == UpdaterStrings.restartToUpdate)
        #expect(service.card == nil)
    }

    @Test func aClickOnTheSettingsControlInstallsAtOnce() {
        let (service, calls) = service()
        service.debugIndicatorPhase = .ready(version: "2")
        service.installClicked()
        #expect(calls.installs == 1)
    }

    @Test func busyAgentsHoldTheClickAndInstallNowAsks() {
        let (service, calls) = service()
        service.debugIndicatorPhase = .ready(version: "2")
        service.blockersChanged(UpdateBlockers(busyAgents: 2))
        service.installClicked()
        #expect(calls.installs == 0)
        #expect(service.card == .waiting(version: "2", busyAgents: 2))
        service.installNow()
        #expect(calls.confirms == [UpdateBlockers(busyAgents: 2)])
        service.interruptAnswered(install: true)
        #expect(calls.installs == 1)
    }

    /// No dialog host yet: Install Now never interrupts busy agents.
    @Test func installNowWithoutADialogHostKeepsWaiting() {
        let (service, calls) = service()
        service.confirmInterrupt = nil
        service.debugIndicatorPhase = .ready(version: "2")
        service.blockersChanged(UpdateBlockers(busyAgents: 1))
        service.installClicked()
        service.installNow()
        #expect(calls.installs == 0)
        #expect(service.card == .waiting(version: "2", busyAgents: 1))
        service.blockersChanged(.none)
        #expect(calls.installs == 1)
    }

    @Test func theHeldClickInstallsWhenTheAgentsFinish() {
        let (service, calls) = service()
        service.debugIndicatorPhase = .ready(version: "2")
        service.blockersChanged(UpdateBlockers(busyAgents: 1))
        service.installClicked()
        service.blockersChanged(.none)
        #expect(calls.installs == 1)
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
    /// Settings control from the status.
    @Test func statusCarriesTheCardAndTheSettingsControl() {
        let (service, _) = service()
        #expect(service.status.card == nil)
        #expect(service.status.badge == nil)
        service.debugIndicatorPhase = .ready(version: "2")
        #expect(service.status.card == nil)
        #expect(service.status.badge == UpdaterStrings.restartToUpdate)
        service.blockersChanged(UpdateBlockers(busyAgents: 1))
        service.installClicked()
        #expect(service.status.card?.kind == "waiting")
    }
}
