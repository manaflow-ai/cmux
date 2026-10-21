import Foundation
@preconcurrency import Sparkle
import Testing
@testable import CmuxUpdater

/// The nightly-next feed lists a build's full DMG first and its Sparkle deltas minutes later.
/// A scheduled check in between must not download the 221 MB DMG when a delta is on its way:
/// it skips that one check, and the next scheduled check takes the update either way.
@MainActor
@Suite struct PendingDeltaWaitTests {
    private static let published = Date(timeIntervalSince1970: 1_792_000_000)
    private static let pubDate: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: published)
    }()

    private func item(deltas: Bool) -> SUAppcastItem {
        var dictionary: [String: Any] = [
            "title": "cmux NEXT 1.0.0-nightly.200",
            "pubDate": Self.pubDate,
            "enclosure": [
                "url": "https://example.com/cmux-nightly-next-macos-arm64-200.dmg",
                "length": "221218951",
                "sparkle:version": "200",
                "sparkle:shortVersionString": "1.0.0-nightly.200",
            ],
        ]
        if deltas {
            dictionary["sparkle:deltas"] = [[
                "url": "https://example.com/cmux-nightly-next-macos-arm64-200-199.delta",
                "length": "6990162",
                "sparkle:version": "200",
                "sparkle:deltaFrom": "199",
            ]]
        }
        return SUAppcastItem(dictionary: dictionary)!
    }

    private func harness(minutesAfterPublication minutes: Double) -> Harness {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.pendingDeltaWindow = 45 * 60
        harness.controller.driver.now = { Self.published.addingTimeInterval(minutes * 60) }
        return harness
    }

    private func find(_ item: SUAppcastItem, _ harness: Harness) -> SPUUserUpdateChoice? {
        let box = ChoiceBox()
        // Sparkle owns this state, but UpdateDriver only needs the appcast item and reply here.
        let sparkleState = unsafeBitCast(NSNull(), to: SPUUserUpdateState.self)
        harness.controller.driver.showUpdateFound(with: item, state: sparkleState, reply: { choice in
            MainActor.assumeIsolated { box.choice = choice }
        })
        return box.choice
    }

    @Test func scheduledCheckSkipsAFreshUpdateWhoseDeltasAreNotListedYet() {
        let harness = harness(minutesAfterPublication: 8)
        #expect(find(item(deltas: false), harness) == .dismiss)
        #expect(harness.model.state.isIdle)
    }

    @Test func theNextScheduledCheckTakesTheUpdateEvenWithoutDeltas() {
        let harness = harness(minutesAfterPublication: 8)
        #expect(find(item(deltas: false), harness) == .dismiss)
        #expect(find(item(deltas: false), harness) == .install)
    }

    @Test func anUpdateThatListsDeltasDownloadsAtOnce() {
        let harness = harness(minutesAfterPublication: 8)
        #expect(find(item(deltas: true), harness) == .install)
    }

    @Test func anUpdateOlderThanTheWindowDownloadsAtOnce() {
        let harness = harness(minutesAfterPublication: 50)
        #expect(find(item(deltas: false), harness) == .install)
    }

    @Test func aCheckThePersonStartedNeverWaits() {
        let harness = harness(minutesAfterPublication: 8)
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(find(item(deltas: false), harness) == .install)
    }

    @Test func withoutAWindowEveryUpdateDownloadsAtOnce() {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
        harness.controller.driver.now = { Self.published.addingTimeInterval(8 * 60) }
        #expect(find(item(deltas: false), harness) == .install)
    }
}
