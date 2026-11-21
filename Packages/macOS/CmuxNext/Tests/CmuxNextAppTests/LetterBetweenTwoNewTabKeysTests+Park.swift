import AppKit
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextFocusUI
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The rows of the park's limit and of its counts in `debug.focus` (`parked_typing`), in the scene of the other rows:
/// a whole window, no daemon, pages that load nothing, each key a key-down event through the key router.
///
/// The letter of the first new tab waits in the park after the second New Tab key. The park has a limit of 2 s from
/// that key: a letter that waited the limit or longer is not typed late into a field that the person does not see.
/// The limit's row has its own clock for the park and moves it by hand: no time passes in the row.
extension LetterBetweenTwoNewTabKeysTests {
    /// The park's clock in a row. The row moves it.
    @MainActor final class ParkClock {
        var now = ContinuousClock.now
    }

    /// The counts of `parked_typing` in `debug.focus`, by name.
    static func parkedTyping(_ services: AppServices) -> [String: Int] {
        let report = DebugFocus.report(services: services)["parked_typing"]
        var counts: [String: Int] = [:]
        for name in ["parked", "typed", "dropped_old", "dropped_page_gone", "dropped_refused", "dropped_returns"] {
            if let count = report?[name]?.doubleValue { counts[name] = Int(count) }
        }
        return counts
    }

    /// New Tab key, a letter, New Tab key, then the page of the first new tab reports its field ready 2 s after the
    /// second New Tab key: the letter is not typed, and `debug.focus` counts it as dropped by its age.
    @Test func aLetterThatWaitedTheLimitIsNotTypedLate() async throws {
        try await Self.withScene { scene in
            let clock = ParkClock()
            scene.router.parkedTyping.now = { clock.now }
            let first = Typed()
            let tab1 = try scene.newTab()
            let page1 = try await scene.pageAfterOneFrame(of: tab1, into: first)
            try scene.held("a", code: 0)
            _ = try scene.newTab()
            let atTheKey = Self.parkedTyping(scene.services)

            clock.now += .seconds(2)
            page1.receive(true)
            await LargeSessionWindowFixture.drainMain()

            let got = first.edits
            let after = Self.parkedTyping(scene.services)
            print("""
                LetterBetweenTwoNewTabKeysTests: a letter, a new tab, the first page ready 2 s later on the park's clock: the app \
                typed \(got) into the first page; parked_typing after the second New Tab key: \(atTheKey.sorted { $0.key < $1.key }), \
                after the page's report: \(after.sorted { $0.key < $1.key }); the hold's log ends: \(scene.holdLog)
                """)
            try await scene.stillReads(page1, into: first)
            #expect(atTheKey["parked"] == 1,
                    "the second New Tab key parked \(atTheKey["parked"] ?? -1) texts, want 1: the row has no parked letter to drop")
            #expect(got.isEmpty, "the app typed \(got) into the page of the first new tab 2 s after the key that parked the letter, want nothing")
            #expect(after == ["parked": 1, "typed": 0, "dropped_old": 1, "dropped_page_gone": 0, "dropped_refused": 0, "dropped_returns": 0],
                    "parked_typing is \(after.sorted { $0.key < $1.key }), want 1 parked and 1 dropped by its age")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
        }
    }

    /// New Tab key, a letter, Return, New Tab key, then the page of the first new tab reports its field ready:
    /// `debug.focus` counts one parked text, one typed text, and the Return that was dropped at the park.
    @Test func debugFocusCountsTheParkedLetterAndTheDroppedReturn() async throws {
        try await Self.withScene { scene in
            let first = Typed()
            let before = Self.parkedTyping(scene.services)
            let tab1 = try scene.newTab()
            let page1 = try await scene.pageAfterOneFrame(of: tab1, into: first)
            try scene.held("a", code: 0)
            try scene.held("\r", code: 36)
            _ = try scene.newTab()
            let atTheKey = Self.parkedTyping(scene.services)
            page1.receive(true)
            await LargeSessionWindowFixture.drainMain()

            let got = first.edits
            let after = Self.parkedTyping(scene.services)
            print("""
                LetterBetweenTwoNewTabKeysTests: parked_typing before the first key: \(before.sorted { $0.key < $1.key }), after \
                the second New Tab key: \(atTheKey.sorted { $0.key < $1.key }), after the first page's report: \
                \(after.sorted { $0.key < $1.key }); the app typed \(got) into the first page; the hold's log ends: \(scene.holdLog)
                """)
            try await scene.stillReads(page1, into: first)
            #expect(before == ["parked": 0, "typed": 0, "dropped_old": 0, "dropped_page_gone": 0, "dropped_refused": 0, "dropped_returns": 0],
                    "parked_typing before the first key is \(before.sorted { $0.key < $1.key }), want the 6 counts at 0")
            #expect(atTheKey == ["parked": 1, "typed": 0, "dropped_old": 0, "dropped_page_gone": 0, "dropped_refused": 0, "dropped_returns": 1],
                    "parked_typing after the second New Tab key is \(atTheKey.sorted { $0.key < $1.key }), want 1 parked and 1 dropped Return")
            #expect(after == ["parked": 1, "typed": 1, "dropped_old": 0, "dropped_page_gone": 0, "dropped_refused": 0, "dropped_returns": 1],
                    "parked_typing after the page's report is \(after.sorted { $0.key < $1.key }), want 1 parked, 1 typed and 1 dropped Return")
            #expect(got == [.insert("a")], "the app typed \(got) into the page of the first new tab, want the letter one time")
        }
    }

    /// A test page whose focus moves one more time while the app's first insertion is on its way.
    @MainActor final class MovedFocus {
        /// The focus count that each insertion of the app named, in the order of the calls.
        var counts: [Int?] = []
        /// What the field took.
        var taken: [PageInputReadiness.Edit] = []
    }

    /// New Tab key, a letter, New Tab key. The page of the first new tab reports its field ready at its focus count 1,
    /// and its focus moves one more time while the app's insertion is on its way: the page refuses the insertion that
    /// names the count 1, and the app has the count 2 when that call ends. The real New Tab page did this in runs on a
    /// Mac. The letter is typed one more time, with the count 2, and `debug.focus` counts it as typed.
    @Test func aLetterWhosePageMovedItsFocusDuringTheInsertionIsTypedWithTheNewCount() async throws {
        try await Self.withScene { scene in
            let tab1 = try scene.newTab()
            let page1 = try await scene.pageAfterOneFrame(of: tab1, into: Typed())
            let field = MovedFocus()
            // The test page: the count message of the second focus move comes inside the first call, the page
            // refuses each call that does not name the count 2, and the field of the count 2 takes the text.
            page1.editor = { [weak page1] edit, count in
                field.counts.append(count)
                if field.counts.count == 1 { page1?.receive(["epoch": 2] as [String: Any]) }
                guard count == 2 else { return false }
                field.taken.append(edit)
                return true
            }
            try scene.held("a", code: 0)
            _ = try scene.newTab()
            let atTheKey = Self.parkedTyping(scene.services)

            page1.receive(["epoch": 1] as [String: Any])
            page1.receive(true)
            await LargeSessionWindowFixture.drainMain()

            let after = Self.parkedTyping(scene.services)
            let named = field.counts.map { count in count.map { String($0) } ?? "none" }
            print("""
                LetterBetweenTwoNewTabKeysTests: a letter, a new tab, the first page moves its focus inside the app's first \
                insertion: the focus counts that the app's insertions named: \(named); \
                the field took \(field.taken); the app's count of the page at the end: \(page1.focusEpoch); parked_typing after \
                the second New Tab key: \(atTheKey.sorted { $0.key < $1.key }), at the end: \(after.sorted { $0.key < $1.key })
                """)
            let parkedAndCalled = atTheKey["parked"] == 1 && !field.counts.isEmpty && field.counts[0] == 1
            try #require(parkedAndCalled,
                         "setup: the row needs 1 parked letter and a first insertion that names the count 1 (parked: \(atTheKey["parked"] ?? -1), the counts of the calls: \(named))")
            #expect(field.taken == [.insert("a")],
                    "the field of the first new tab took \(field.taken), want the letter one time; the app's insertions named the counts \(named), want 1 then 2")
            #expect(after == ["parked": 1, "typed": 1, "dropped_old": 0, "dropped_page_gone": 0, "dropped_refused": 0, "dropped_returns": 0],
                    "parked_typing is \(after.sorted { $0.key < $1.key }), want 1 parked and 1 typed")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
        }
    }

    /// New Tab key, a letter, New Tab key. The page of the first new tab does not report, and the park's clock passes
    /// the limit of 2 s. The person goes back to the first new tab, and the first key there is a Return. The parked
    /// letter is too old to be typed, so no text waits for that page: the key router passes the Return on, as it did
    /// before the park was there. It does not hold the Return behind a text that never comes.
    @Test func aReturnInATabWhoseParkedLetterWaitedTheLimitIsPassedOn() async throws {
        try await Self.aKeyInATabWhoseParkedLetterWaitedTheLimit("\r", code: 36, name: "Return")
    }

    /// The same with a Delete as the first key in the first new tab: the key router passes it on. It does not take
    /// the Delete for a text that no longer waits.
    @Test func aDeleteInATabWhoseParkedLetterWaitedTheLimitIsPassedOn() async throws {
        try await Self.aKeyInATabWhoseParkedLetterWaitedTheLimit("\u{7F}", code: 51, name: "Delete")
    }

    private static func aKeyInATabWhoseParkedLetterWaitedTheLimit(_ characters: String, code: UInt16, name: String) async throws {
        try await Self.withScene { scene in
            let clock = ParkClock()
            scene.router.parkedTyping.now = { clock.now }
            let first = Typed()
            let tab1 = try scene.newTab()
            let page1 = try await scene.pageAfterOneFrame(of: tab1, into: first)
            try scene.held("a", code: 0)
            let tab2 = try scene.newTab()
            let atTheKey = Self.parkedTyping(scene.services)
            let page2 = try await scene.pageAfterOneFrame(of: tab2, into: Typed())
            // The page of the second new tab reports with the token of its key hold, as the page does, and its field
            // reports ready: that hold ends. A hold that is still there takes a Delete before the type-ahead code.
            let tabs = scene.services.agentTabs
            let token = try #require(tabs.newTabPages[tabs.tabKey(tab2)]?.page.inputToken,
                                     "setup: the page of the second new tab has no token of a key hold")
            scene.input.acknowledge(token, in: scene.window)
            page2.receive(true)
            await LargeSessionWindowFixture.drainMain()

            // The page of the first new tab does not report. The limit passes on the park's clock. The row does not
            // read `debug.focus` from here to the key: that read drops a text that is too old.
            clock.now += .seconds(2)
            // The person goes back to the first new tab: the pane shows its page again.
            let tab = try #require(scene.pane.orderedIDs.first { $0.rawValue == tab1 }, "setup: the first new tab is not in the strip")
            scene.pane.select(tab)
            await Self.frame(scene.services)
            await LargeSessionWindowFixture.drainMain()
            let shows = scene.pane.currentTabKey == tab1 && scene.pane.currentContent?.inputReadiness === page1
            let canQueue = scene.controller.focus.state.resolved.mayQueueTyping
            try #require(atTheKey["parked"] == 1,
                         "setup: the second New Tab key parked \(atTheKey["parked"] ?? -1) texts, want 1: the row has no parked letter")
            try #require(shows && canQueue && !page1.isReady,
                         """
                         setup: the row needs the page of the first new tab as the pane's page again, with a field that is not \
                         ready and a focus that can queue typing (the pane shows that page: \(shows), the focus can queue typing: \
                         \(canQueue), the field is ready: \(page1.isReady))
                         """)
            try #require(!scene.router.creationInputCoordinator.isHolding(in: scene.window) && !scene.input.isHolding(in: scene.window),
                         """
                         setup: a hold of the window is still there before the \(name) key and can take it (the creation hold: \
                         \(scene.router.creationInputCoordinator.isHolding(in: scene.window)), the New Tab key hold: \
                         \(scene.input.isHolding(in: scene.window))). The key hold's log ends: \(scene.holdLog)
                         """)

            // The first key in the first new tab.
            let key = try scene.keys.press(characters, code: code, command: false)
            let heldBehindText = scene.router.typeAheadTail.holds(String(describing: ObjectIdentifier(page1)))
            let decided = scene.router.decided.contains(key.event)
            let afterTheKey = Self.parkedTyping(scene.services)

            // A late report of the page.
            page1.receive(true)
            await LargeSessionWindowFixture.drainMain()
            let got = first.edits
            let ranAgain = scene.givenOn.keys.filter { $0.code == code }.count
            print("""
                LetterBetweenTwoNewTabKeysTests: a parked letter that waited the limit, then a \(name) key in its tab: the key \
                router took the key: \(key.took) (it decided the key: \(decided); it held the key behind a text of the page: \
                \(heldBehindText)); after the page's late report the key ran again \(ranAgain) times and the app typed \(got) \
                into the page; parked_typing after the second New Tab key: \(atTheKey.sorted { $0.key < $1.key }), after the \
                \(name) key: \(afterTheKey.sorted { $0.key < $1.key }); the hold's log ends: \(scene.holdLog)
                """)
            try await scene.stillReads(page1, into: first)
            #expect(!key.took,
                    """
                    the key router took the \(name) key in a tab whose parked letter waited the limit, want the key passed on: \
                    no text waits for that page. The router held the key behind a text of the page: \(heldBehindText); after \
                    the page's late report the key ran again \(ranAgain) times.
                    """)
            #expect(got.isEmpty, "the app typed \(got) into the page of the first new tab after the limit, want nothing")
            #expect(afterTheKey == ["parked": 1, "typed": 0, "dropped_old": 1, "dropped_page_gone": 0, "dropped_refused": 0, "dropped_returns": 0],
                    "parked_typing after the \(name) key is \(afterTheKey.sorted { $0.key < $1.key }), want 1 parked and 1 dropped by its age")
        }
    }
}
