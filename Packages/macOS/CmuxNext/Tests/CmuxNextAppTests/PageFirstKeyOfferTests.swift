import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The keys a Chromium page has first (`PageFirstKeyOffer`): a second key offered before the page reported the
/// first (Cmd-F then Cmd-G, a key repeat) no longer replaces it, a report releases older keys of its own tab only, and
/// a report from another tab than the one the key was offered to runs nothing (focus can move before Chromium reports).
@MainActor @Suite
struct PageFirstKeyOfferTests {
    private static func key(_ characters: String, keyCode: UInt16, at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: timestamp,
                                             windowNumber: 0, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private static func held(_ id: ActionID) -> PageFirstKeyOffer.Held {
        PageFirstKeyOffer.Held(candidate: KeyRouter.Candidate(id: id, tier: .navigation, source: .registry(argument: nil)),
                               context: KeyContext(bits: []), window: "w")
    }

    @Test func aSecondOfferKeepsTheFirstKey() throws {
        let tab = NSObject()
        var offers = PageFirstKeyOffer()
        let find = try Self.key("f", keyCode: 3, at: 10)
        let next = try Self.key("g", keyCode: 5, at: 11)
        offers.offer(find, Self.held("find"), to: tab)
        offers.offer(next, Self.held("findNext"), to: tab)
        #expect(offers.take(find, from: tab)?.candidate.id == "find", "the first key was replaced by the second")
        #expect(offers.take(next, from: tab)?.candidate.id == "findNext")
        #expect(offers.count == 0)
    }

    @Test func aReportReleasesItsKeyAndTheOlderOnes() throws {
        let tab = NSObject()
        var offers = PageFirstKeyOffer()
        let handled = try Self.key("f", keyCode: 3, at: 20)  // the page handled it: no report comes
        let unhandled = try Self.key("g", keyCode: 5, at: 21)
        offers.offer(handled, Self.held("find"), to: tab)
        offers.offer(unhandled, Self.held("findNext"), to: tab)
        #expect(offers.take(unhandled, from: tab)?.candidate.id == "findNext")
        #expect(offers.take(handled, from: tab) == nil, "a key older than a reported one is still held")
    }

    /// Chromium reports keys in order only within one renderer: tabs in other renderer processes report in any
    /// order. Cmd-F to tab A (its renderer busy), then a click on tab B and Cmd-G: B's report comes first and must
    /// not drop A's held Find.
    @Test func anotherTabsReportKeepsAnOlderKey() throws {
        let first = NSObject(), second = NSObject()
        var offers = PageFirstKeyOffer()
        let find = try Self.key("f", keyCode: 3, at: 40)
        let next = try Self.key("g", keyCode: 5, at: 41)
        offers.offer(find, Self.held("find"), to: first)
        offers.offer(next, Self.held("findNext"), to: second)
        #expect(offers.take(next, from: second)?.candidate.id == "findNext")
        #expect(offers.take(find, from: first)?.candidate.id == "find", "another tab's report dropped the key")
        #expect(offers.count == 0)
    }

    /// The bound is per tab: a tab that handles every page-first key (no report ever comes) drops only its own oldest
    /// keys, never another tab's held key.
    @Test func theBoundDropsOnlyTheFullTabsOldestKey() throws {
        let busy = NSObject(), other = NSObject()
        var offers = PageFirstKeyOffer()
        let held = try Self.key("f", keyCode: 3, at: 50)
        offers.offer(held, Self.held("find"), to: other)
        let oldest = try Self.key("g", keyCode: 5, at: 51)
        offers.offer(oldest, Self.held("findNext"), to: busy)
        for index in 0..<PageFirstKeyOffer.limit {
            let repeated = try Self.key("g", keyCode: 5, at: 52 + Double(index))
            offers.offer(repeated, Self.held("findNext"), to: busy)
        }
        #expect(offers.count == PageFirstKeyOffer.limit + 1)
        #expect(offers.take(oldest, from: busy) == nil, "the full tab kept more than its bound")
        #expect(offers.take(held, from: other)?.candidate.id == "find", "a full tab dropped another tab's key")
    }

    @Test func aReportFromAnotherTabRunsNothing() throws {
        let offered = NSObject(), other = NSObject()
        var offers = PageFirstKeyOffer()
        let find = try Self.key("f", keyCode: 3, at: 30)
        offers.offer(find, Self.held("find"), to: offered)
        #expect(offers.take(find, from: other) == nil, "another tab's report ran the offered tab's action")
    }

    /// A tab whose page handles every page-first key it gets (Google Docs takes Copy, Paste and Find) never reports:
    /// once the tab closes, its held keys go. They stayed for the whole session, up to the bound for every tab ever
    /// opened, and every later offer and report walked them.
    @Test func aClosedTabsKeysAreReleased() throws {
        var offers = PageFirstKeyOffer()
        do {
            let closed = NSObject()
            for index in 0..<3 {
                offers.offer(try Self.key("f", keyCode: 3, at: 60 + Double(index)), Self.held("find"), to: closed)
            }
        }
        let open = NSObject()
        offers.offer(try Self.key("g", keyCode: 5, at: 70), Self.held("findNext"), to: open)
        #expect(offers.count == 1, "a closed tab's held keys stayed")
    }
}
