import Foundation
import Testing
@testable import CmuxUpdater

/// The Sparkle seam (`SparkleSeam.swift`) translates Sparkle's callbacks into ``UpdateDriver``
/// calls and the driver's answers back into Sparkle's values. These tests drive the bridge the
/// way Sparkle does and read what Sparkle would receive, with no Sparkle import: the reply
/// closures get Sparkle's own `SPUUserUpdateChoice`, recorded by raw value.
@MainActor
@Suite struct SparkleSeamTests {
    private let model = UpdateStateModel()

    /// The raw values of the `SPUUserUpdateChoice` replies Sparkle received.
    @MainActor
    private final class SparkleReplies {
        var rawValues: [Int] = []
    }

    private func makeDriver() -> UpdateDriver {
        UpdateDriver(model: model, log: NoopUpdateLog(), clock: TestDeadlineClock())
    }

    @Test func readyReplyReachesSparkleAsInstall() {
        let driver = makeDriver()
        let bridge = SparkleDriverBridge(driver: driver)
        let replies = SparkleReplies()

        bridge.showReady(toInstallAndRelaunch: { choice in
            MainActor.assumeIsolated { replies.rawValues.append(choice.rawValue) }
        })

        #expect(replies.rawValues == [UpdateChoice.install.rawValue])
    }

    /// A staged background update's installer is cancelled with Sparkle's Skip, which records
    /// no skipped version (not Dismiss, which would leave the installer to run on quit).
    @Test func cancelledStagedInstallReachesSparkleAsSkip() {
        let driver = makeDriver()
        driver.installsInBackground = true
        let bridge = SparkleDriverBridge(driver: driver)
        let replies = SparkleReplies()

        bridge.showReady(toInstallAndRelaunch: { choice in
            MainActor.assumeIsolated { replies.rawValues.append(choice.rawValue) }
        })
        #expect(replies.rawValues.isEmpty, "a background install holds Sparkle's reply until the host acts")
        #expect(driver.cancelStaged())

        #expect(replies.rawValues == [UpdateChoice.skip.rawValue])
    }

    @Test func choicesKeepSparklesRawValues() {
        // `SPUUserUpdateChoice`: Skip = 0, Install = 1, Dismiss = 2. The update log prints these.
        #expect(UpdateChoice.skip.rawValue == 0)
        #expect(UpdateChoice.install.rawValue == 1)
        #expect(UpdateChoice.dismiss.rawValue == 2)
        // `SPUUpdateCheck`: Updates = 0, UpdatesInBackground = 1, UpdateInformation = 2.
        #expect(UpdateCheckKind.updates.rawValue == 0)
        #expect(UpdateCheckKind.updatesInBackground.rawValue == 1)
        #expect(UpdateCheckKind.updateInformation.rawValue == 2)
    }

    @Test func userCheckReachesTheDriverThroughTheBridge() {
        let driver = makeDriver()
        let bridge = SparkleDriverBridge(driver: driver)

        bridge.showUserInitiatedUpdateCheck(cancellation: {})

        guard case .checking = model.state else {
            Issue.record("the bridge must forward a user check to the driver; state=\(model.state)")
            return
        }
    }

    @Test func appcastItemReadsSparklesValues() throws {
        let item = try #require(UpdateAppcastItem(dictionary: [
            "title": "cmux 0.64.17",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "description": "Fixes.",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": "6417",
                "sparkle:shortVersionString": "0.64.17",
            ],
        ]))
        #expect(item.versionString == "6417")
        #expect(item.displayVersionString == "0.64.17")
        #expect(item.contentLength == 1024)
        #expect(item.fileURL?.absoluteString == "https://example.com/cmux.zip")
        #expect(item.itemDescription == "Fixes.")
        #expect(item.date != nil)
        #expect(!item.listsDeltas)
    }

    @Test func versionComparatorUsesSparklesOrder() {
        let comparator = SparkleVersionComparator()
        #expect(comparator.compare("1.0.9", "1.0.10") == .orderedAscending)
        #expect(comparator.compare("200", "199") == .orderedDescending)
        #expect(comparator.compare("1.2", "1.2") == .orderedSame)
    }
}
