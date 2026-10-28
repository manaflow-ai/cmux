import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The keys a Chromium page has first (`PageFirstKeyOffer`): a second key offered before the page reported the
/// first (Cmd-F then Cmd-G, a key repeat) no longer replaces it, and a report from another tab than the one the key
/// was offered to runs nothing (focus can move before Chromium reports).
@MainActor @Suite
struct PageFirstKeyOfferTests {
    private static func key(_ characters: String, keyCode: UInt16, at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: timestamp,
                                             windowNumber: 0, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private static func held(_ id: ActionID, tab: AnyObject) -> PageFirstKeyOffer.Held {
        PageFirstKeyOffer.Held(candidate: KeyRouter.Candidate(id: id, tier: .navigation, source: .registry(argument: nil)),
                               context: KeyContext(bits: []), window: "w", tab: ObjectIdentifier(tab))
    }

    @Test func aSecondOfferKeepsTheFirstKey() throws {
        let tab = NSObject()
        var offers = PageFirstKeyOffer()
        let find = try Self.key("f", keyCode: 3, at: 10)
        let next = try Self.key("g", keyCode: 5, at: 11)
        offers.offer(find, Self.held("find", tab: tab))
        offers.offer(next, Self.held("findNext", tab: tab))
        #expect(offers.take(find, from: ObjectIdentifier(tab))?.candidate.id == "find", "the first key was replaced by the second")
        #expect(offers.take(next, from: ObjectIdentifier(tab))?.candidate.id == "findNext")
        #expect(offers.count == 0)
    }

    @Test func aReportReleasesItsKeyAndTheOlderOnes() throws {
        let tab = NSObject()
        var offers = PageFirstKeyOffer()
        let handled = try Self.key("f", keyCode: 3, at: 20)  // the page handled it: no report comes
        let unhandled = try Self.key("g", keyCode: 5, at: 21)
        offers.offer(handled, Self.held("find", tab: tab))
        offers.offer(unhandled, Self.held("findNext", tab: tab))
        #expect(offers.take(unhandled, from: ObjectIdentifier(tab))?.candidate.id == "findNext")
        #expect(offers.take(handled, from: ObjectIdentifier(tab)) == nil, "a key older than a reported one is still held")
    }

    @Test func aReportFromAnotherTabRunsNothing() throws {
        let offered = NSObject(), other = NSObject()
        var offers = PageFirstKeyOffer()
        let find = try Self.key("f", keyCode: 3, at: 30)
        offers.offer(find, Self.held("find", tab: offered))
        #expect(offers.take(find, from: ObjectIdentifier(other)) == nil, "another tab's report ran the offered tab's action")
    }
}
