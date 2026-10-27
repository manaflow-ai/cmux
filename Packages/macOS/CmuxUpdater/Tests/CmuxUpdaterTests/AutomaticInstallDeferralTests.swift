import Foundation
@preconcurrency import Sparkle
import Testing
@testable import CmuxUpdater

/// Host double that holds automatic installs while `holds` is set and keeps the release it was given.
@MainActor
private final class DeferringHost: UpdateActionDelegate {
    var holds = true
    var asked = 0
    var ready: (@MainActor () -> Void)?

    func updaterRequestsRetryCheckForUpdates() {}
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers { .empty }
    func updaterDefersAutomaticInstall(until ready: @escaping @MainActor () -> Void) -> Bool {
        asked += 1
        guard holds else { return false }
        self.ready = ready
        return true
    }
}

/// Host double with the protocol's default: it never holds an automatic install (classic).
@MainActor
private final class PlainHost: UpdateActionDelegate {
    func updaterRequestsRetryCheckForUpdates() {}
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers { .empty }
}

/// An idle-policy install the host holds (``UpdateActionDelegate/updaterDefersAutomaticInstall(until:)``):
/// nothing installs until the host's release, a click installs at once, and a release for an update
/// that is gone does nothing.
@MainActor
@Suite struct AutomaticInstallDeferralTests {
    private let model = UpdateStateModel()

    private func makeDriver(_ host: some UpdateActionDelegate) -> UpdateDriver {
        let driver = UpdateDriver(model: model, log: NoopUpdateLog(), clock: TestDeadlineClock())
        driver.actionDelegate = host
        driver.installsInBackground = true
        driver.installsWhenIdle = true
        return driver
    }

    private func stage(_ driver: UpdateDriver, into box: ChoiceBox) {
        driver.showReady(toInstallAndRelaunch: { choice in
            MainActor.assumeIsolated { box.choice = choice }
        })
    }

    @Test func aHostThatHoldsNothingInstallsAtOnce() {
        let host = PlainHost()
        let driver = makeDriver(host)
        let reply = ChoiceBox()
        stage(driver, into: reply)
        #expect(reply.choice == .install)
        #expect(driver.relaunchIsAutomatic)
    }

    @Test func aHeldInstallWaitsForTheHostsRelease() {
        let host = DeferringHost()
        let driver = makeDriver(host)
        let reply = ChoiceBox()
        stage(driver, into: reply)

        #expect(host.asked == 1)
        #expect(reply.choice == nil)
        #expect(driver.stagedInstall != nil)
        #expect(model.text == "Restart to Complete Update")

        host.ready?()
        #expect(reply.choice == .install)
        #expect(driver.relaunchIsAutomatic)
        #expect(driver.stagedInstall == nil)
    }

    @Test func aClickWhileHeldInstallsAtOnceAndTheLateReleaseDoesNothing() {
        let host = DeferringHost()
        let driver = makeDriver(host)
        let reply = ChoiceBox()
        stage(driver, into: reply)
        guard case .installing(let installing) = model.state else {
            Issue.record("expected the staged state, got \(model.state)")
            return
        }

        installing.retryTerminatingApplication()
        #expect(reply.choice == .install)
        #expect(!driver.relaunchIsAutomatic)

        reply.choice = nil
        host.ready?()
        #expect(reply.choice == nil)
        #expect(!driver.relaunchIsAutomatic)
    }

    @Test func aReleaseForAReplacedUpdateDoesNothing() {
        let host = DeferringHost()
        let driver = makeDriver(host)
        let first = ChoiceBox()
        stage(driver, into: first)
        let stale = host.ready

        let second = ChoiceBox()
        stage(driver, into: second)
        #expect(host.asked == 2)

        stale?()
        #expect(first.choice == nil)
        #expect(second.choice == nil)
        #expect(driver.stagedInstall != nil)

        host.ready?()
        #expect(second.choice == .install)
    }

    @Test func aClickWhileDownloadingIsNeverHeld() {
        let host = DeferringHost()
        let driver = makeDriver(host)
        driver.installsWhenStaged = true
        let reply = ChoiceBox()
        stage(driver, into: reply)
        #expect(host.asked == 0)
        #expect(reply.choice == .install)
        #expect(!driver.relaunchIsAutomatic)
    }
}
