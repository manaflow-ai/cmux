import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import CmuxNextSettings
import Foundation
import Testing

/// The two counts of `debug.focus` for the New Tab keys and the Close Tab keys that a hold of the window's keys kept
/// (`creation_hold_tab_keys`): `cancelled_pairs`, the pairs of a kept New Tab key and the kept Close Tab key after it
/// that an end of the hold let go together, and `lost_close_keys`, the kept Close Tab keys that a forced end dropped.
///
/// Decision of 2026-11-16: an act never runs before the act of a key that the person pressed before it. A forced end
/// runs the kept keys at the thing that has the focus then, so it drops a kept Close Tab key that has no New Tab key
/// that it can cancel. That is a lost key: the person pressed it and the app did nothing for it. The count is the only
/// sign of it.
///
/// The app on a fresh same-tree daemon, with the keys and the helpers of `ACloseTabKeyAfterKeptNewTabKeysTests`, whose
/// rows have the same keys and check the tabs. The rows here check the two counts only. Each row starts a new app, and
/// the counts are since the app started.
///
/// Limits:
/// - The limits of `ACloseTabKeyAfterKeptNewTabKeysTests`: no HID event, the keys of a test in one turn of the main
///   actor.
/// - The counts are new with the change that keeps the Close Tab key: these rows have no red first.
/// - The forced end is the reply bound of a hold that the test opens itself, with a value of 1 second in place of the
///   product's value.
/// - A failure of a line that starts with `setup:` is no result.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AHoldsEndCountsItsTabKeyPairsAndLostCloseKeysTests {
    private typealias Rows = ACloseTabKeyAfterKeptNewTabKeysTests

    /// The two counts of `debug.focus`: the cancelled pairs, then the lost Close Tab keys.
    static func counts(_ services: AppServices) -> [Double?] {
        let report = DebugFocus.report(services: services)["creation_hold_tab_keys"]
        return [report?["cancelled_pairs"]?.doubleValue, report?["lost_close_keys"]?.doubleValue]
    }

    /// A normal end. The first New Tab key makes a terminal and opens the hold: Cmd-T, Cmd-T, Cmd-W, in one turn, and
    /// the hold keeps the second and the third key. Its end lets those two go together: 1 pair, no lost key.
    @Test func aNormalEndCountsThePairOfAKeptNewTabKeyAndAKeptCloseTabKey() async throws {
        try await Rows.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let keys = Rows.Keys(services: services, window: window, log: log)
            try #require(Self.counts(services) == [0, 0], "setup: the counts are \(Self.counts(services)) before the keys (want 0 and 0)")
            // One turn of the main actor: the daemon's answer to the first creation cannot come between the keys.
            let first = try keys.newTab()
            try #require(first == .ran && services.keyRouter.creationInputCoordinator.isHolding(in: window),
                         "setup: the first New Tab key did not run, or it opened no hold; \(keys.said)")
            let second = try keys.newTab(), close = try keys.closeTab()
            try #require(second == .kept && close == .kept, "setup: the hold did not keep the second New Tab key and the Close Tab key; \(keys.said)")
            try await Rows.settle(keys, in: window, services: services)
            let counted = Self.counts(services)
            #expect(counted == [1, 0], "the debug read counts \(counted) (want 1 cancelled pair, then 0 lost Close Tab keys); \(keys.said)")
        }
    }

    /// A forced end. The test opens a hold with a creation that never answers, so the hold ends at its reply bound
    /// (1 second here). The keys of a row come in one turn, and the hold keeps each. The test waits for the forced end
    /// by its event: the hold's log names the reply bound as its end, or a kept key ran again. Each row has 1 pair (its
    /// first Close Tab key with the New Tab key before it); the last row has a second Close Tab key, which is lost.
    @Test(arguments: zip(["Cmd-T Cmd-T Cmd-W", "Cmd-T Cmd-W", "Cmd-T Cmd-W Cmd-W"], [0, 0, 1]))
    func aForcedEndCountsItsPairsAndItsLostCloseTabKeys(typed: String, lostCloseKeys: Int) async throws {
        try await Rows.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let holds = services.keyRouter.creationInputCoordinator
            holds.replyWaitLimit = .seconds(1)
            let controller = try #require(services.windows.active, "setup: the app has no window")
            let ticket = try #require(holds.begin(in: window, generation: controller.focus.beginIntent(), tab: "pending_tab_that_never_answers"),
                                      "setup: no hold opened for the creation that never answers")
            // The bound of 1 second is the test's hold's only: a hold that a kept key opens when it runs again has the product's bound.
            holds.replyWaitLimit = CreationInputBuffer.replyWaitBound
            let keys = Rows.Keys(services: services, window: window, log: log)
            try #require(Self.counts(services) == [0, 0], "setup: the counts are \(Self.counts(services)) before the keys (want 0 and 0)")
            // One turn of the main actor, inside the hold.
            for key in typed.split(separator: " ") {
                let outcome = try key == "Cmd-W" ? keys.closeTab() : keys.newTab()
                try #require(outcome == .kept, "setup: the hold did not keep the key \(key); \(keys.said)")
            }
            try await PasswordManagerRouteTests.until({ holds.lastHoldEnd(in: window) == .replyBoundReached || log.replays > 0 },
                                                      report: { "setup: the hold did not end at its reply bound; \(keys.said)" })
            try await Rows.settle(keys, in: window, services: services)
            let counted = Self.counts(services), want: [Double?] = [1, Double(lostCloseKeys)]
            #expect(counted == want, "the debug read counts \(counted) (want 1 cancelled pair, then \(lostCloseKeys) lost Close Tab keys); \(keys.said)")
            holds.resolve(ticket, landed: false, in: window)
        }
    }
}
