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
}
