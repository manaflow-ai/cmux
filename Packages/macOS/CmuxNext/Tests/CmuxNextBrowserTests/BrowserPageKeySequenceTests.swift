@testable import CmuxNextBrowser
import Foundation
import Testing

/// Vimium's `gg` in a browser page (user, 2026-11-10: "like in browser i just press f and it
/// works"): two `g` within a second scroll to the top; anything between them, or a late
/// second `g`, starts over, and every other letter runs its own key at once.
struct BrowserPageKeySequenceTests {
    private static let g = BrowserPageKey(character: "g", shift: false)
    private static let start = ContinuousClock.now

    @Test func twoGsInASecondScrollToTheTop() {
        var keys = BrowserPageKeySequence()
        #expect(keys.feed(Self.g, at: Self.start) == .held)
        #expect(keys.feed(Self.g, at: Self.start + .milliseconds(300)) == .scrollToTop)
        #expect(keys.feed(Self.g, at: Self.start + .milliseconds(400)) == .held, "a third g starts a new gg")
    }

    @Test func aLateSecondGWaitsAgain() {
        var keys = BrowserPageKeySequence()
        #expect(keys.feed(Self.g, at: Self.start) == .held)
        #expect(keys.feed(Self.g, at: Self.start + .milliseconds(1500)) == .held)
        #expect(keys.feed(Self.g, at: Self.start + .milliseconds(1700)) == .scrollToTop)
    }

    @Test func anotherKeyBetweenTheGsRunsAndStartsOver() {
        var keys = BrowserPageKeySequence()
        let j = BrowserPageKey(character: "j", shift: false)
        #expect(keys.feed(Self.g, at: Self.start) == .held)
        #expect(keys.feed(j, at: Self.start + .milliseconds(100)) == .key(j))
        #expect(keys.feed(Self.g, at: Self.start + .milliseconds(200)) == .held)
    }

    @Test func shiftGRunsAtOnce() {
        var keys = BrowserPageKeySequence()
        let bottom = BrowserPageKey(character: "g", shift: true)
        #expect(keys.feed(bottom, at: Self.start) == .key(bottom))
        #expect(keys.feed(Self.g, at: Self.start + .milliseconds(100)) == .held)
        #expect(keys.feed(bottom, at: Self.start + .milliseconds(200)) == .key(bottom), "Shift-G after g is G, not gg")
        #expect(keys.feed(Self.g, at: Self.start + .milliseconds(300)) == .held)
    }

    @Test func resetForgetsAWaitingG() {
        var keys = BrowserPageKeySequence()
        #expect(keys.feed(Self.g, at: Self.start) == .held)
        keys.reset()
        #expect(keys.feed(Self.g, at: Self.start + .milliseconds(100)) == .held)
    }

    /// WebKit pages report the letters they left unhandled through a message handler: the page
    /// controls the payload, so only one ASCII letter counts.
    @Test(arguments: [("j", "j", false), ("G", "g", true), ("f", "f", false), ("F", "f", true)])
    func aReportedLetterIsAPageKey(payload: String, character: String, shift: Bool) {
        #expect(BrowserPageKey(reported: payload) == BrowserPageKey(character: character, shift: shift))
    }

    @Test(arguments: ["", "jj", "1", " ", "é", "<", "\u{1F600}", "ab"])
    func anythingElseIsNot(payload: String) {
        #expect(BrowserPageKey(reported: payload) == nil)
    }
}
