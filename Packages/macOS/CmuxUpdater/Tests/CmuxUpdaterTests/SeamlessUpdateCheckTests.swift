import Foundation
import Testing
@testable import CmuxUpdater

/// Checks that make updates feel pushed: a launch check that downloads for hosts that never
/// prompt, a check after the Mac wakes, and the one-time upgrade of a stale 24h interval.
@MainActor
@Suite struct SeamlessUpdateCheckTests {
    // MARK: - Launch check

    @Test func backgroundInstallHostChecksForRealAtLaunch() {
        let harness = Harness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        harness.updater.automaticallyChecksForUpdates = true
        harness.controller.installsUpdatesInBackground = true

        #expect(harness.controller.startUpdaterIfNeeded())

        #expect(harness.updater.backgroundCheckCount == 1)
        #expect(harness.updater.informationCheckCount == 0)
    }

    @Test func promptingHostKeepsTheInformationOnlyLaunchProbe() {
        let harness = Harness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        harness.updater.automaticallyChecksForUpdates = true

        #expect(harness.controller.startUpdaterIfNeeded())

        #expect(harness.updater.informationCheckCount == 1)
        #expect(harness.updater.backgroundCheckCount == 0)
    }

    // MARK: - Wake check

    @Test func wakeChecksWhenTheLastCheckIsOld() {
        let harness = Harness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        harness.updater.automaticallyChecksForUpdates = true
        harness.controller.installsUpdatesInBackground = true
        harness.controller.startUpdaterIfNeeded()
        harness.updater.sessionInProgress = false
        let now = Date()

        #expect(harness.controller.checkAfterWake(lastCheck: now.addingTimeInterval(-3 * 3600), now: now))
        #expect(harness.updater.backgroundCheckCount == 2)
    }

    @Test func wakeSkipsWhileAnUpdateDownloads() {
        let harness = Harness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        harness.updater.automaticallyChecksForUpdates = true
        harness.controller.startUpdaterIfNeeded()
        harness.model.setState(.downloading(.init(cancel: {}, expectedLength: nil, progress: 0)))

        #expect(!harness.controller.checkAfterWake(lastCheck: nil))
        #expect(harness.updater.backgroundCheckCount == 0)
    }

    @Test func wakeCheckRunsAfterTheDelayOnTheInjectedClock() async {
        let harness = Harness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        harness.updater.automaticallyChecksForUpdates = true
        harness.controller.installsUpdatesInBackground = true
        harness.controller.startUpdaterIfNeeded()
        #expect(harness.updater.backgroundCheckCount == 1)

        harness.controller.systemDidWake()
        let task = harness.controller.wakeCheckTask
        #expect(harness.updater.backgroundCheckCount == 1)
        await harness.clock.fireDeadlineWhenReady()
        await task?.value

        #expect(harness.updater.backgroundCheckCount == 2)
    }

    @Test func wakeSkipsWhenSparkleCheckedMomentsAgo() {
        let harness = Harness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        harness.updater.automaticallyChecksForUpdates = true
        harness.controller.startUpdaterIfNeeded()
        let now = Date()

        #expect(!harness.controller.checkAfterWake(lastCheck: now.addingTimeInterval(-60), now: now))
        #expect(harness.updater.backgroundCheckCount == 0)
    }

    @Test func wakeNeverChecksWithAutomaticChecksOffOrBeforeStart() {
        let harness = Harness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        harness.updater.automaticallyChecksForUpdates = true
        // Not started yet.
        #expect(!harness.controller.checkAfterWake(lastCheck: nil))

        harness.controller.startUpdaterIfNeeded()
        harness.updater.automaticallyChecksForUpdates = false
        #expect(!harness.controller.checkAfterWake(lastCheck: nil))
        #expect(harness.updater.backgroundCheckCount == 0)
    }

}
