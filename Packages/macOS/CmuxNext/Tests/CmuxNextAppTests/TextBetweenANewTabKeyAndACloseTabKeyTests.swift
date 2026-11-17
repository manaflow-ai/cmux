import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import Foundation
import Testing

/// Text between a kept New Tab key and a Close Tab key: New Tab, text, Close Tab, while a hold of the window's keys is
/// open and keeps the New Tab key.
///
/// An act never runs before the act of a key that the person pressed before it. The text is for
/// the tab of the New Tab key, and the Close Tab key is for that tab too. A hold's end lets a Close Tab key and the New
/// Tab key before it go together when no other key is between them (`ACloseTabKeyAfterKeptNewTabKeysTests`). Text
/// between them stops that: if the two keys went together, the text was left, and it ran in a tab that was there before
/// the keys. So the keys run as the person pressed them:
/// - at a normal end the New Tab key makes its tab, the text goes to that tab, and the Close Tab key closes that tab;
/// - at a forced end (the hold's reply bound) the kept keys run at the thing that has the focus then, so a Close Tab
///   key with no New Tab key that it can cancel is dropped (a lost key, and `debug.focus` counts it): the New Tab key
///   makes its tab, the text goes to that tab, and the tab stays open.
///
/// The app on a fresh same-tree daemon, with the keys and the helpers of `ACloseTabKeyAfterKeptNewTabKeysTests`. A New
/// Tab key makes a terminal here (the pane's daemon holds no agent tabs). The text is `zq` and four digits, each a
/// key-down with no modifier through the key router, with no Return.
///
/// Where the text went: each terminal that is open at the end first runs a line that the test sends to it by the
/// daemon (the line prints `kd42`). When that shows, the terminal handled each key that came before it, and the test
/// reads its screen one time. There is no fixed wait for a thing that must not show: the end of the keys' work is
/// `settle` of `ACloseTabKeyAfterKeptNewTabKeysTests` (named facts, then one answer of the daemon).
///
/// Limits:
/// - The limits of `ACloseTabKeyAfterKeptNewTabKeysTests`: no HID event, the keys of a test in one turn of the main
///   actor, the store's tab lists and the terminals' text, not the pixels.
/// - Text only: no row has an app shortcut of another kind between the two keys.
/// - The normal end is the end of a hold that a New Tab key opened. The forced end is the reply bound of a hold that the
///   test opens itself, with a value of 1 second in place of the product's value.
/// - A failure of a line that starts with `setup:` is no result.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TextBetweenANewTabKeyAndACloseTabKeyTests {
    private typealias Rows = ACloseTabKeyAfterKeptNewTabKeysTests

    /// Types `text` as plain keys. The hold keeps each (a text key that goes to a terminal at once is no row of this suite).
    private static func type(_ text: String, _ keys: Rows.Keys) throws {
        for character in text {
            let typed = try keys.press("the text key \(character)", String(character), code: 0, repeats: false, flags: [])
            try #require(typed.outcome == .kept, "setup: the hold did not keep a text key; \(keys.said)")
        }
    }

    /// The terminals that are open now and show `text`, each with the end of its screen.
    private static func terminals(showing text: String, _ services: AppServices) async throws -> [(id: String, screen: String)] {
        let connection = try #require(services.daemon.connection, "setup: the app has no connection to its daemon")
        var showing: [(id: String, screen: String)] = []
        for tab in PasswordManagerRouteTests.tabs(services) where tab.kind == .pty && !ProvisionalTab.isProvisional(surface: tab.surface) {
            // Return first: text that waits at the prompt runs (the shell names it), then the marker line.
            try await connection.send(tab.surface, text: "\recho kd$((6*7))\r")
            let screen = try await connection.request(WaitForTextRequest(surface: tab.surface, pattern: "kd42", timeoutMs: 20_000), timeout: .seconds(25))
            try #require(screen.matched == true, "setup: terminal \(tab.id) did not run the test's marker line; its screen: \(screen.text.suffix(300))")
            if screen.text.contains(text) { showing.append((tab.id, String(screen.text.suffix(300)))) }
        }
        return showing
    }

    /// A normal end. The first New Tab key makes a terminal and opens the hold: Cmd-T, Cmd-T, the text, Cmd-W, in one
    /// turn. At the end: one new tab, the terminal of the first key. The text went to the tab of the second key, which
    /// the Close Tab key closed: no terminal that is open at the end shows it.
    @Test func textBetweenAKeptNewTabKeyAndACloseTabKeyRunsInNoTabThatStays() async throws {
        try await Rows.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let keys = Rows.Keys(services: services, window: window, log: log)
            let text = "zq\(UInt32.random(in: 1000...9999))"
            var failure: (any Error)?
            do {
                // One turn of the main actor: the daemon's answer to the first creation cannot come between the keys.
                let first = try keys.newTab()
                try #require(first == .ran && services.keyRouter.creationInputCoordinator.isHolding(in: window),
                             "setup: the first New Tab key did not run, or it opened no hold; \(keys.said)")
                let second = try keys.newTab()
                try #require(second == .kept, "setup: the hold did not keep the second New Tab key; \(keys.said)")
                try Self.type(text, keys)
                try keys.closeTab()
                try await Rows.settle(keys, in: window, services: services)
            } catch { failure = error }
            Rows.check(keys, "a held New Tab key that makes terminals, a New Tab key, text, a Close Tab key", lateAnswers: 1)
            let counted = AHoldsEndCountsItsTabKeyPairsAndLostCloseKeysTests.counts(services)
            #expect(counted == [0, 0], "the debug read counts \(counted) (want 0 cancelled pairs, then 0 lost Close Tab keys: the keys ran as the person pressed them); \(keys.said)")
            if failure == nil {
                let showing = try await Self.terminals(showing: text, services)
                #expect(showing.isEmpty,
                        "the text for the new tab that the Close Tab key closed shows in \(showing.count) terminals that are open at the end: \(showing); \(keys.said)")
            }
            if let failure { throw failure }
        }
    }

    /// A forced end. The test opens a hold with a creation that never answers, so the hold ends at its reply bound
    /// (1 second here): Cmd-T, the text, Cmd-W, in one turn, and the hold keeps each. At the end: one new tab, the
    /// terminal of the New Tab key, and it is the only terminal that shows the text; no tab that was there before the
    /// keys is closed. The test waits for the forced end by its event: the hold's log names the reply bound as its
    /// end, or a kept key ran again. Then it reads the end's name: it must be the reply bound.
    @Test func textBetweenAKeptNewTabKeyAndACloseTabKeyGoesToTheNewTabWhenTheHoldEndsAtItsReplyBound() async throws {
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
            let text = "zq\(UInt32.random(in: 1000...9999))"
            var failure: (any Error)?, close: Rows.Keys.Outcome?, end: CreationHoldEnd?
            do {
                // One turn of the main actor, inside the hold.
                let newTab = try keys.newTab()
                try #require(newTab == .kept, "setup: the hold did not keep the New Tab key; \(keys.said)")
                try Self.type(text, keys)
                close = try keys.closeTab()
                if close == .kept {
                    try await PasswordManagerRouteTests.until({ holds.lastHoldEnd(in: window) == .replyBoundReached || log.replays > 0 },
                                                              report: { "setup: the hold did not end at its reply bound; \(keys.said)" })
                    end = Rows.endOfTheFirstHold(log, in: window, services: services)
                }
                try await Rows.settle(keys, in: window, services: services)
            } catch { failure = error }
            let new = keys.newTabs, gone = keys.oldTabsGone
            print("KEYS-IN-ORDER a hold that ends by force, Cmd-T text Cmd-W: \(keys.count) keys, \(keys.keptNewTabKeys) New Tab keys kept by a hold, \(new.count) new tabs at the end")
            #expect(close == .kept, "the Close Tab key that came after a kept New Tab key and text was not kept by the hold; \(keys.said)")
            #expect(end == .replyBoundReached, "the test's hold ended as \(end.map { "\($0)" } ?? "not known") (want its reply bound); \(keys.said)")
            #expect(gone.isEmpty && keys.oldTabsClosedAfterANewTabKey.isEmpty, "the keys closed \(gone), tabs that were there before the first key; \(keys.said)")
            #expect(new.count == 1, "at the end \(new.count) new tabs (want 1, the tab of the New Tab key): \(new); \(keys.said)")
            let counted = AHoldsEndCountsItsTabKeyPairsAndLostCloseKeysTests.counts(services)
            #expect(counted == [0, 1], "the debug read counts \(counted) (want 0 cancelled pairs, then 1 lost Close Tab key); \(keys.said)")
            holds.resolve(ticket, landed: false, in: window)
            if failure == nil {
                let showing = try await Self.terminals(showing: text, services)
                #expect(showing.map { $0.id } == new, "the text shows in \(showing) (want the new tabs only: \(new)); \(keys.said)")
            }
            if let failure { throw failure }
        }
    }
}
