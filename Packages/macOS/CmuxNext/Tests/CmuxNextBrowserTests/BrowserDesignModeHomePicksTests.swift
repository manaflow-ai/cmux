import Testing
@testable import CmuxNextBrowser

/// Chief's Home chat holds a pick as its card's attachment. When the person removes the chip, or
/// sends the draft, the pick's pin leaves the page, the same as from the agent chat (Chief,
/// 2026-11-21).
@Suite struct BrowserDesignModeHomePicksTests {
    @Test func aPickWhoseChipLeftTheDraftIsReleasedOnce() {
        var picks = BrowserDesignModeHomePicks()
        picks.record("one", added: ["a"])
        picks.record("two", added: ["b"])
        #expect(picks.released(keeping: ["a", "b", "other"]) == [])
        #expect(picks.released(keeping: ["b"]) == ["one"], "the chip's x took the first pick")
        #expect(picks.released(keeping: ["b"]) == [], "released once")
        #expect(picks.take("one") == nil)
    }

    @Test func sendingTheDraftReleasesEveryPick() {
        var picks = BrowserDesignModeHomePicks()
        picks.record("two", added: ["b"])
        picks.record("one", added: ["a", "c"])
        #expect(picks.released(keeping: []) == ["one", "two"])
    }

    @Test func aPickStaysWhileAnyOfItsAttachmentsIsInTheDraft() {
        var picks = BrowserDesignModeHomePicks()
        picks.record("one", added: ["a", "c"])
        #expect(picks.released(keeping: ["c"]) == [])
        #expect(picks.take("one") == ["a", "c"])
    }

    @Test func aPickThatAddedNothingIsNeverReleased() {
        var picks = BrowserDesignModeHomePicks()
        picks.record("one", added: [])
        #expect(picks.released(keeping: []) == [])
    }
}
