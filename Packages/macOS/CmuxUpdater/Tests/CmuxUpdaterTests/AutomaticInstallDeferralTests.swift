import Foundation
import Testing
@testable import CmuxUpdater

/// Host double that holds automatic installs while `holds` is set and keeps the release it was given.
@MainActor
private final class DeferringHost: UpdateActionDelegate {
    var holds = true
    var asked = 0
    var ready: (@MainActor () -> Void)?
    var ended = 0

    func updaterRequestsRetryCheckForUpdates() {}
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers { .empty }
    func updaterDefersAutomaticInstall(until ready: @escaping @MainActor () -> Void) -> Bool {
        asked += 1
        guard holds else { return false }
        self.ready = ready
        return true
    }
    func updaterEndsAutomaticInstallHold() { ended += 1 }
}

/// Host double that quits the app for an automatic install and reopens itself (#25904's self-quit),
/// still waiting for the moment to clear when a click comes.
@MainActor
private final class QuittingHost: UpdateActionDelegate {
    var ended = 0

    func updaterRequestsRetryCheckForUpdates() {}
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers { .empty }
    func updaterQuitsForAutomaticInstall(build: String) -> Bool { true }
    func updaterEndsAutomaticInstallHold() { ended += 1 }
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
        #expect(host.ended == 1)

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

    @Test func cancellingAHeldUpdateEndsTheHostsHold() {
        let host = DeferringHost()
        let driver = makeDriver(host)
        stage(driver, into: ChoiceBox())
        #expect(driver.cancelStaged())
        #expect(host.ended == 1)
    }

    @Test func anAutomaticRelaunchIsHeldAtSparklesRelaunchToo() {
        let host = DeferringHost()
        host.holds = false
        let driver = makeDriver(host)
        driver.holdsUserInstalls = false
        stage(driver, into: ChoiceBox())
        #expect(driver.relaunchIsAutomatic)

        // A sheet came up while Sparkle installed.
        host.holds = true
        var relaunches = 0
        #expect(driver.handleShouldPostponeRelaunch(installHandler: { relaunches += 1 }))
        #expect(relaunches == 0)
        #expect(model.text == "Restart to Complete Update")

        host.ready?()
        #expect(relaunches == 1)
        host.ready?()
        #expect(relaunches == 1)
    }

    @Test func aClickOnAHeldRelaunchRelaunchesOnce() {
        let host = DeferringHost()
        host.holds = false
        let driver = makeDriver(host)
        driver.holdsUserInstalls = false
        stage(driver, into: ChoiceBox())
        host.holds = true
        var relaunches = 0
        #expect(driver.handleShouldPostponeRelaunch(installHandler: { relaunches += 1 }))
        guard case .installing(let installing) = model.state else {
            Issue.record("expected the held state, got \(model.state)")
            return
        }
        installing.retryTerminatingApplication()
        #expect(relaunches == 1)
        #expect(host.ended == 1)
        host.ready?()
        #expect(relaunches == 1)
    }

    @Test func aClickedRelaunchIsNeverHeld() {
        let host = DeferringHost()
        let driver = makeDriver(host)
        driver.holdsUserInstalls = false
        driver.installsWhenStaged = true
        stage(driver, into: ChoiceBox())
        let asked = host.asked
        #expect(!driver.handleShouldPostponeRelaunch(installHandler: {}))
        #expect(host.asked == asked)
    }

    @Test func aClickWhileTheAppWaitsToQuitForTheInstallInstallsAtOnce() {
        let host = QuittingHost()
        let driver = makeDriver(host)
        driver.holdsUserInstalls = false
        driver.backgroundItem = Self.item
        let reply = ChoiceBox()
        stage(driver, into: reply)

        // The app quits for the install and its quit waits: Sparkle's reply stays held, and the
        // update shows as staged, so the click has something to install.
        #expect(reply.choice == nil)
        #expect(driver.stagedItem?.versionString == "0.64.17")
        guard case .installing(let installing) = model.state, installing.isAutoUpdate else {
            Issue.record("expected the staged state, got \(model.state)")
            return
        }

        installing.retryTerminatingApplication()
        #expect(reply.choice == .install, "the click installs now, not an empty retry")
        #expect(!driver.relaunchIsAutomatic)
        #expect(host.ended == 1, "the host's wait ends without quitting")
        #expect(driver.quitInstall == nil)

        reply.choice = nil
        #expect(!driver.installQuitInstallNow(), "a second click finds nothing to install")
        #expect(reply.choice == nil)
    }

    @Test func aClickAfterTheQuitIsCommittedInstallsNothingMore() {
        let host = QuittingHost()
        let driver = makeDriver(host)
        driver.holdsUserInstalls = false
        driver.backgroundItem = Self.item
        let reply = ChoiceBox()
        stage(driver, into: reply)
        guard case .installing(let staged) = model.state else {
            Issue.record("expected the staged state, got \(model.state)")
            return
        }

        // The wait ended and the helper quits the app: it reopens it, so Sparkle must not.
        driver.commitQuitInstall()
        #expect(driver.stagedItem == nil)
        staged.retryTerminatingApplication()
        #expect(!driver.installQuitInstallNow())
        #expect(reply.choice == nil, "only the helper reopens the app")

        // The quit was refused: staged again, and a click installs.
        #expect(driver.restageAfterDeclinedQuit())
        #expect(driver.installStaged())
        #expect(reply.choice == .install)
    }

    @Test func theUserComingInDuringTheQuitWaitIsNoLongerStaged() {
        let host = QuittingHost()
        let driver = makeDriver(host)
        driver.holdsUserInstalls = false
        driver.backgroundItem = Self.item
        let reply = ChoiceBox()
        stage(driver, into: reply)
        #expect(driver.relaunchHeldInstallThroughSparkle())
        #expect(reply.choice == .install)
        #expect(model.text != "Restart to Complete Update", "Sparkle relaunches now: nothing waits for a click")
        #expect(driver.stagedItem == nil)
    }

    private static var item: UpdateAppcastItem {
        UpdateAppcastItem(dictionary: [
            "title": "cmux 0.64.17",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": "0.64.17",
                "sparkle:shortVersionString": "0.64.17",
            ],
        ])!
    }

    @Test func aHeldRelaunchStillNamesTheStagedUpdate() {
        let item = UpdateAppcastItem(dictionary: [
            "title": "cmux 0.64.17",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": "0.64.17",
                "sparkle:shortVersionString": "0.64.17",
            ],
        ])!
        let host = DeferringHost()
        host.holds = false
        let driver = makeDriver(host)
        driver.holdsUserInstalls = false
        driver.backgroundItem = item
        stage(driver, into: ChoiceBox())
        host.holds = true
        #expect(driver.handleShouldPostponeRelaunch(installHandler: {}))
        #expect(driver.stagedItem?.versionString == "0.64.17")

        host.ready?()
        #expect(driver.automaticInstallItem == nil)
    }
}
