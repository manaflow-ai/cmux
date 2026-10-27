import Foundation
@preconcurrency import Sparkle
import Testing
@testable import CmuxUpdater

@MainActor
@Suite struct BackgroundInstallTests {
    private let item = SUAppcastItem(dictionary: [
        "title": "cmux 0.64.17",
        "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
        "enclosure": [
            "url": "https://example.com/cmux.zip",
            "length": "1024",
            "sparkle:version": "0.64.17",
            "sparkle:shortVersionString": "0.64.17",
        ],
    ])!

    private func find(_ harness: Harness, into box: ChoiceBox) {
        // Sparkle owns this state, but UpdateDriver only needs the appcast item and reply here.
        let sparkleState = unsafeBitCast(NSNull(), to: SPUUserUpdateState.self)
        harness.controller.driver.showUpdateFound(with: item, state: sparkleState, reply: { choice in
            MainActor.assumeIsolated { box.choice = choice }
        })
    }

    private func ready(_ harness: Harness, into box: ChoiceBox) {
        harness.controller.driver.showReady(toInstallAndRelaunch: { choice in
            MainActor.assumeIsolated { box.choice = choice }
        })
    }

    /// Pumps the cooperative pool until `condition` holds (the controller's reactions run as
    /// main-actor tasks).
    private func waitUntil(_ what: String,
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() {
            await Task.yield()
        }
        #expect(condition(), "timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func persisted(_ harness: Harness) -> NSDictionary {
        (harness.defaults.persistentDomain(forName: harness.suiteName) ?? [:]) as NSDictionary
    }

    @Test func offByDefaultKeepsThePromptFlowAndDefaults() {
        let harness = Harness()
        let before = persisted(harness)
        #expect(harness.controller.installsUpdatesInBackground == false)

        let found = ChoiceBox()
        find(harness, into: found)
        guard case .updateAvailable(let available) = harness.model.state else {
            Issue.record("expected the Update Available prompt, got \(harness.model.state)")
            return
        }
        #expect(found.choice == nil)
        #expect(available.reply.isConsumed == false)

        let readyBox = ChoiceBox()
        ready(harness, into: readyBox)
        #expect(readyBox.choice == .install)
        #expect(harness.controller.stagedUpdate == nil)
        #expect(persisted(harness) == before)
    }

    @Test func backgroundModeDownloadsAFoundUpdateWithoutPrompting() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true

        let found = ChoiceBox()
        find(harness, into: found)

        #expect(found.choice == .install)
        if case .updateAvailable = harness.model.state {
            Issue.record("background mode must not surface the Update Available prompt")
        }
    }

    /// Background mode owns the staged installer so the app can replace it when a newer feed
    /// item arrives. A persisted Sparkle silent-install preference would bypass that replacement
    /// path and make Restart to Update install an older build first.
    @Test func backgroundModeDisablesSparkleSilentInstallPath() {
        let harness = Harness(automaticDownloads: true)
        #expect(harness.defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        harness.controller.installsUpdatesInBackground = true
        #expect(!harness.defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
    }

    @Test func backgroundModeSkipsThePromptForAUserInitiatedCheckToo() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})

        let found = ChoiceBox()
        find(harness, into: found)

        #expect(found.choice == .install)
        if case .updateAvailable = harness.model.state {
            Issue.record("a manual check must not surface the Update Available prompt in background mode")
        }
    }

    @Test func backgroundModeHoldsTheReadyUpdateUntilTheUserInstalls() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        find(harness, into: ChoiceBox())

        let readyBox = ChoiceBox()
        ready(harness, into: readyBox)

        #expect(readyBox.choice == nil)
        #expect(harness.controller.stagedUpdate?.displayVersionString == "0.64.17")
        guard case .installing(let installing) = harness.model.state else {
            Issue.record("expected the staged ready state, got \(harness.model.state)")
            return
        }
        #expect(installing.isAutoUpdate)

        harness.controller.installStagedUpdate()
        #expect(readyBox.choice == .install)
        #expect(harness.controller.stagedUpdate == nil)

        readyBox.choice = nil
        harness.controller.installStagedUpdate()
        #expect(readyBox.choice == nil)
    }

    /// Lawrence 2026-10-23 ("dyt we can just remove this"): a nightly's idle install held for
    /// 9 busy agents and 5 commands showed a "Waiting to Relaunch" card. The hold now shows as the
    /// staged update, so the person's click on it is an install they asked for: it relaunches at
    /// once instead of failing as "install clicked with no staged update".
    @Test func aClickOnAnIdleInstallHeldForBusyWorkRelaunchesNow() {
        let harness = Harness()
        let host = HeldBlockersHost()
        harness.controller.driver.actionDelegate = host
        let installs = CallCounterBox()
        harness.controller.driver.relaunchIsAutomatic = true
        #expect(harness.controller.driver.handleShouldPostponeRelaunch(item: item, installHandler: { installs.count += 1 }))
        #expect(harness.controller.driver.relaunchGate.isWaiting)
        #expect(harness.controller.stagedUpdate?.displayVersionString == "0.64.17",
                "the held update has no version, so the rail hides it and nothing can relaunch it")

        harness.controller.installStagedUpdate()

        #expect(installs.count == 1, "the click did not relaunch the held install")
        #expect(!harness.controller.driver.relaunchGate.isWaiting)
        if case .error = harness.model.state {
            Issue.record("the click on a held install became an error: \(harness.model.state)")
        }
    }

    @Test func aClickDuringTheDownloadInstallsAsSoonAsItIsReady() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        find(harness, into: ChoiceBox())
        harness.controller.installWhenStaged()

        let readyBox = ChoiceBox()
        ready(harness, into: readyBox)

        #expect(readyBox.choice == .install)
        #expect(harness.controller.stagedUpdate == nil)
    }

    @Test func aClickThatFindsNothingDoesNotInstallALaterDownload() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.installWhenStaged()
        harness.controller.driver.showUpdateNotFoundWithError(NSError(domain: "test", code: 0), acknowledgement: {})

        find(harness, into: ChoiceBox())
        let readyBox = ChoiceBox()
        ready(harness, into: readyBox)

        #expect(readyBox.choice == nil)
        #expect(harness.controller.stagedUpdate != nil)
    }

    /// The controller ends an install attempt itself ("Updater is still starting", the install
    /// watchdog) without going through the driver; a later download must still wait for a click.
    @Test func aControllerSideErrorDropsAClickToInstallWhenReady() async {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.installWhenStaged()
        harness.model.setState(.error(.init(error: NSError(domain: "test", code: 1), retry: {}, dismiss: {})))
        for _ in 0..<20_000 where harness.controller.driver.installsWhenStaged { await Task.yield() }

        find(harness, into: ChoiceBox())
        let readyBox = ChoiceBox()
        ready(harness, into: readyBox)

        #expect(readyBox.choice == nil)
        #expect(harness.controller.stagedUpdate != nil)
    }

    /// Sparkle's own silent driver (`SUAutomaticallyUpdate`) stages through
    /// `willInstallUpdateOnQuit`, not this driver: the host still learns which
    /// build waits, so it can show its version and never offer the build it runs.
    @Test func sparklesSilentInstallNamesTheStagedUpdate() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        let updater = unsafeBitCast(NSNull(), to: SPUUpdater.self)
        _ = harness.controller.driver.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {})
        #expect(harness.controller.stagedUpdate?.versionString == "0.64.17")
        #expect(harness.controller.stagedUpdate?.displayVersionString == "0.64.17")

        harness.controller.installStagedUpdate()
        #expect(harness.controller.stagedUpdate == nil, "the installing update still reads as staged")
    }

    @Test func backgroundModeWritesNothingToDefaults() {
        let harness = Harness()
        let before = persisted(harness)
        harness.controller.installsUpdatesInBackground = true
        find(harness, into: ChoiceBox())
        ready(harness, into: ChoiceBox())
        harness.controller.installStagedUpdate()
        #expect(persisted(harness) == before)
    }

    /// `updates.installOnQuit` off (cmux-next): a quit cancels the held
    /// installer with Sparkle's Skip reply on the ready-to-install prompt,
    /// which cancels the installer without recording a skipped version, so
    /// the next check offers the update again.
    @Test func cancellingAStagedUpdateRepliesSkipOnceAndClearsIt() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        find(harness, into: ChoiceBox())
        let readyBox = ChoiceBox()
        ready(harness, into: readyBox)
        #expect(harness.controller.stagedUpdate != nil)

        harness.controller.cancelStagedUpdate()
        #expect(readyBox.choice == .skip)
        #expect(harness.controller.stagedUpdate == nil)

        readyBox.choice = nil
        harness.controller.cancelStagedUpdate()
        harness.controller.installStagedUpdate()
        #expect(readyBox.choice == nil)
    }

    /// `updates.downloadAutomatically` off: a found update waits as the
    /// prompt; the user's click downloads it and it stages like a
    /// background download (the host installs it).
    @Test func withDownloadsOffAFoundUpdateWaitsForTheClick() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.downloadsUpdatesInBackground = false
        let found = ChoiceBox()
        find(harness, into: found)
        #expect(found.choice == nil)
        guard case .updateAvailable = harness.model.state else {
            Issue.record("expected the waiting prompt, got \(harness.model.state)")
            return
        }
        harness.controller.acceptAvailableUpdate()
        #expect(found.choice == .install)
        let readyBox = ChoiceBox()
        ready(harness, into: readyBox)
        #expect(readyBox.choice == nil)
        #expect(harness.controller.stagedUpdate?.displayVersionString == "0.64.17")
    }

    /// `updates.downloadAutomatically` off (or a metered network) and the user
    /// clicks Install Update: the controller runs a fresh check and answers
    /// Sparkle's update-found prompt itself. The build that download stages is
    /// the one the user asked for, so it must be known; a staged update of
    /// unknown version is one the host hides and (before #22874's review fix)
    /// cancelled, dropping a newer build the user had just asked for.
    @Test func anInstallClickWithDownloadsOffStagesTheBuildItFound() async {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.downloadsUpdatesInBackground = false

        harness.controller.attemptUpdate()
        await waitUntil("the fresh check") { harness.updater.checkForUpdatesCallCount == 1 }
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        let found = ChoiceBox()
        find(harness, into: found)
        await waitUntil("the install reply") { found.choice == .install }
        harness.controller.driver.showDownloadInitiated(cancellation: {})

        let readyBox = ChoiceBox()
        ready(harness, into: readyBox)
        #expect(readyBox.choice == nil, "the staged update was answered before the user installed it")
        #expect(harness.controller.stagedUpdate?.versionString == "0.64.17",
                "the build the Install click downloaded staged with no item: the host cannot tell it is newer")

        harness.controller.installStagedUpdate()
        #expect(readyBox.choice == .install)
    }

    /// A test feed (cmux-next NIGHTLY/DEV, "Use Test Update Feed") replaces the baked feed for
    /// every check; clearing it returns to the baked feed. Signatures are unchanged.
    @Test func aFeedOverrideReplacesTheBakedFeed() {
        let harness = Harness()
        let baked = harness.controller.driver.resolvedFeedURL()
        harness.controller.feedOverride = "https://example.com/test/appcast.xml"
        #expect(harness.controller.driver.resolvedFeedURL() == "https://example.com/test/appcast.xml")
        harness.controller.feedOverride = nil
        #expect(harness.controller.driver.resolvedFeedURL() == baked)
    }

    /// After a rollback, the build rolled back from (and anything older) is not offered
    /// again; a newer build is.
    @Test func skippedBuildsAreNotOfferedAgain() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.skipsBuildsThrough = "0.64.17"
        let found = ChoiceBox()
        find(harness, into: found)
        #expect(found.choice == .dismiss)
        #expect(harness.controller.stagedUpdate == nil)

        harness.controller.skipsBuildsThrough = "0.64.16"
        let newer = ChoiceBox()
        find(harness, into: newer)
        #expect(newer.choice == .install)
    }
}

/// Host that answers whether it quits and reopens itself for an automatic install.
@MainActor
private final class ReopeningHost: UpdateActionDelegate {
    var reopens: Bool
    var asked: [String] = []
    init(reopens: Bool) { self.reopens = reopens }
    func updaterRequestsRetryCheckForUpdates() {}
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers { .empty }
    func updaterQuitsForAutomaticInstall(build: String) -> Bool {
        asked.append(build)
        return reopens
    }
}

/// An automatic install whose host reopens itself never answers Sparkle's ready reply (Sparkle
/// installs as the app exits, with no relaunch through LaunchServices); a click, or a host that
/// does not reopen, installs and relaunches through Sparkle as before.
@MainActor
@Suite struct AutomaticInstallReopenTests {
    private let item = SUAppcastItem(dictionary: [
        "title": "cmux 0.64.17",
        "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
        "enclosure": ["url": "https://example.com/cmux.zip", "length": "1024",
                      "sparkle:version": "0.64.17", "sparkle:shortVersionString": "0.64.17"],
    ])!

    private func stage(_ harness: Harness, host: ReopeningHost, automatic: Bool) -> ChoiceBox {
        let driver = harness.controller.driver
        driver.actionDelegate = host
        harness.controller.installsUpdatesInBackground = true
        harness.controller.holdsUserInstalls = false
        harness.controller.installsUpdatesWhenIdle = automatic
        let sparkleState = unsafeBitCast(NSNull(), to: SPUUserUpdateState.self)
        driver.showUpdateFound(with: item, state: sparkleState, reply: { _ in })
        let ready = ChoiceBox()
        driver.showReady(toInstallAndRelaunch: { choice in MainActor.assumeIsolated { ready.choice = choice } })
        return ready
    }

    @Test func aHostThatReopensLeavesTheReplyForTheQuit() {
        let harness = Harness()
        let host = ReopeningHost(reopens: true)
        let ready = stage(harness, host: host, automatic: true)
        #expect(host.asked == ["0.64.17"])
        #expect(ready.choice == nil, "Sparkle must not relaunch: it installs as the app exits")
        #expect(harness.controller.stagedUpdate == nil)
        #expect(!harness.controller.driver.relaunchIsAutomatic)

        // The quit was refused: the update is staged again (Sparkle's reply still held), once.
        harness.controller.restageAfterDeclinedQuit()
        #expect(ready.choice == nil, "a refused quit never relaunches through Sparkle (that activates)")
        #expect(harness.controller.stagedUpdate?.versionString == "0.64.17")
        guard case .installing(let staged) = harness.model.state, staged.isAutoUpdate else {
            Issue.record("expected the staged state, got \(harness.model.state)")
            return
        }
        harness.controller.restageAfterDeclinedQuit()
        // The user's click then installs and relaunches through Sparkle.
        harness.controller.installStagedUpdate()
        #expect(ready.choice == .install)
        #expect(host.asked == ["0.64.17"], "a click never asks the host to reopen")
    }

    /// The user came into the app before the quit: Sparkle installs and relaunches, once.
    @Test func aHeldInstallRelaunchesThroughSparkleWhenTheUserComesIn() {
        let harness = Harness()
        let host = ReopeningHost(reopens: true)
        let ready = stage(harness, host: host, automatic: true)
        #expect(ready.choice == nil)
        harness.controller.relaunchHeldInstallThroughSparkle()
        #expect(ready.choice == .install)
        ready.choice = nil
        harness.controller.relaunchHeldInstallThroughSparkle()
        harness.controller.restageAfterDeclinedQuit()
        #expect(ready.choice == nil, "once")
        #expect(harness.controller.stagedUpdate == nil)
    }

    @Test func aHostThatDoesNotReopenRelaunchesThroughSparkle() {
        let harness = Harness()
        let host = ReopeningHost(reopens: false)
        let ready = stage(harness, host: host, automatic: true)
        #expect(host.asked == ["0.64.17"])
        #expect(ready.choice == .install)
    }

    @Test func aClickNeverAsksTheHostToReopen() {
        let harness = Harness()
        let host = ReopeningHost(reopens: true)
        let ready = stage(harness, host: host, automatic: false)
        harness.controller.installStagedUpdate()
        #expect(host.asked.isEmpty)
        #expect(ready.choice == .install, "a clicked install relaunches through Sparkle, which activates")
    }

    @Test func aHostWithTheRelaunchGateIsNotAsked() {
        let harness = Harness()
        let host = ReopeningHost(reopens: true)
        let driver = harness.controller.driver
        driver.actionDelegate = host
        harness.controller.installsUpdatesInBackground = true
        harness.controller.installsUpdatesWhenIdle = true
        let sparkleState = unsafeBitCast(NSNull(), to: SPUUserUpdateState.self)
        driver.showUpdateFound(with: item, state: sparkleState, reply: { _ in })
        let ready = ChoiceBox()
        driver.showReady(toInstallAndRelaunch: { choice in MainActor.assumeIsolated { ready.choice = choice } })
        #expect(host.asked.isEmpty)
        #expect(ready.choice == .install)
    }
}

/// Host that reports busy agents and running commands, as the nightly did when the card showed.
@MainActor
private final class HeldBlockersHost: UpdateActionDelegate {
    func updaterRequestsRetryCheckForUpdates() {}
    func updaterPrepareAutomaticInstall() -> Bool { true }
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers {
        UpdateRelaunchBlockers(busyAgentCount: 9, runningCommandCount: 5)
    }
}

private final class CallCounterBox: @unchecked Sendable {
    var count = 0
}
