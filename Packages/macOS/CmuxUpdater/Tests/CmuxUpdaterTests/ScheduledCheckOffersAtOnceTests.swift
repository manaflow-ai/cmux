import Foundation
@preconcurrency import Sparkle
import Testing
@testable import CmuxUpdater

/// The nightly-next feed lists a build's full DMG first and its Sparkle deltas minutes later. A
/// scheduled check in between offers the update at once, full archive and all: no check holds a
/// build back for its deltas (sr2, 2026-10-26: "The pending-delta skip must never hold back a build
/// when a newer one exists: offer the full update and let the deltas follow.").
@MainActor
@Suite struct ScheduledCheckOffersAtOnceTests {
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

    private func harness() -> Harness {
        let harness = Harness()
        harness.controller.installsUpdatesInBackground = true
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

    @Test func aScheduledCheckTakesAFreshUpdateWhoseDeltasAreNotListedYet() {
        let harness = harness()
        #expect(find(item(deltas: false), harness) == .install)
    }

    @Test func aScheduledCheckTakesAnUpdateThatListsDeltas() {
        let harness = harness()
        #expect(find(item(deltas: true), harness) == .install)
    }

    @Test func aCheckThePersonStartedTakesAFreshUpdate() {
        let harness = harness()
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(find(item(deltas: false), harness) == .install)
    }
}
