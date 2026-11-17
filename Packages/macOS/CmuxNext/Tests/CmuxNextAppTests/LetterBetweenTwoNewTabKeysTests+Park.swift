import AppKit
@testable import CmuxNextApp
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
}
