import Foundation
import Testing
@testable import CmuxNextDesign

/// Leo (2026-10-08 dogfood): the workspace hover card is instant, and moving
/// between rows retargets it with no fade gap. A target with no delay shows
/// on its first hit; a card that loses its target stays a moment, so the
/// next row (past a header or a gap) slides it over instead of fading it out
/// and in.
@Suite struct HoverCardInstantTests {
    let instant = HoverTarget(id: HoverTargetID("ws:a"), window: 1, delay: .zero)
    let other = HoverTarget(id: HoverTargetID("ws:b"), window: 1, delay: .zero)

    @Test func aTargetWithNoDelayShowsOnItsFirstHit() {
        var machine = HoverCardMachine()
        #expect(machine.reduce(.hit(instant, moved: true)) == [.show(instant, sliding: false)])
        #expect(machine.shownTarget == instant)
        #expect(machine.armedToken == nil)
    }

    @Test func crossingAGapSlidesTheCardToTheNextRow() {
        var machine = HoverCardMachine()
        _ = machine.reduce(.hit(instant, moved: true))
        let leaving = machine.reduce(.hit(nil, moved: true))
        #expect(!leaving.contains(.hide), "the card stays while the pointer crosses a gap")
        #expect(machine.shownTarget == instant)
        let next = machine.reduce(.hit(other, moved: true))
        #expect(next.contains(.show(other, sliding: true)))
        #expect(!next.contains(.hide))
        #expect(machine.shownTarget == other)
        #expect(machine.armedToken == nil)
    }

    @Test func leavingEveryRowHidesTheCardAfterTheLeaveWindow() throws {
        var machine = HoverCardMachine()
        _ = machine.reduce(.hit(instant, moved: true))
        let effects = machine.reduce(.hit(nil, moved: true))
        #expect(effects.contains(.schedule(token: try #require(machine.armedToken), after: machine.leaveWindow)))
        let token = try #require(machine.armedToken)
        let hidden = machine.reduce(.deadline(token: token))
        #expect(hidden.contains(.hide))
        #expect(machine.shownTarget == nil)
    }
}
