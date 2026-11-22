import Foundation
import Testing
@testable import CmuxMobileModel

/// Leo, 2026-11-21: "i lost connection with cosmic gray or some s***... multiple issues to fix there".
/// A tab missing from one publish while the link comes back keeps what the screen holds for it.
@Suite struct MissingGraceTests {
    let start = ContinuousClock.now

    @Test func aTabMissingForOnePublishIsKept() {
        var grace = MissingGrace<String>()
        #expect(grace.expired(held: ["a", "b"], present: ["b"], linkUp: true, now: start).isEmpty)
        #expect(grace.expired(held: ["a", "b"], present: ["a", "b"], linkUp: true, now: start + .seconds(1)).isEmpty)
        // Listed again: the grace starts over.
        #expect(grace.expired(held: ["a", "b"], present: ["b"], linkUp: true, now: start + .seconds(11)).isEmpty)
    }

    @Test func aTabThatStaysMissingOnAConnectedMacGoesAfterTheGrace() {
        var grace = MissingGrace<String>()
        #expect(grace.expired(held: ["a"], present: [], linkUp: true, now: start).isEmpty)
        #expect(grace.expired(held: ["a"], present: [], linkUp: true, now: start + .seconds(9)).isEmpty)
        #expect(grace.expired(held: ["a"], present: [], linkUp: true, now: start + .seconds(10)) == ["a"])
    }

    @Test func theClockDoesNotRunWhileTheLinkIsDown() {
        var grace = MissingGrace<String>()
        #expect(grace.expired(held: ["a"], present: [], linkUp: true, now: start).isEmpty)
        #expect(grace.expired(held: ["a"], present: [], linkUp: false, now: start + .seconds(60)).isEmpty)
        // Back up: a fresh grace, not the minute spent down.
        #expect(grace.expired(held: ["a"], present: [], linkUp: true, now: start + .seconds(61)).isEmpty)
        #expect(grace.expired(held: ["a"], present: [], linkUp: true, now: start + .seconds(72)) == ["a"])
    }
}
