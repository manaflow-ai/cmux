@testable import CmuxNextAgentPane
import CmuxNextSignposts
import Testing

/// An agent or page tab's `create.tab` end (p09-observability task 030,
/// ``PaneFirstPaintGated/createTabFirstFrame(content:)``): content that awaits its first paint ends the interval as
/// shown at that paint, once; content that painted already reports shown in the wait's call, which
/// ``CreateTabTimings`` carries to the commit that shows it.
@MainActor @Suite(.serialized)
struct PaneFirstPaintCreateTabTests {
    @MainActor final class Gated: PaneFirstPaintGated {
        private(set) var awaitsFirstPaint: Bool
        private var bodies: [() -> Void] = []

        init(painted: Bool) { awaitsFirstPaint = !painted }

        func whenFirstPainted(_ body: @escaping () -> Void) {
            if awaitsFirstPaint { bodies.append(body) } else { body() }
        }

        func paint() {
            awaitsFirstPaint = false
            let waiting = bodies
            bodies = []
            for body in waiting { body() }
        }
    }

    @MainActor final class Outcomes {
        private(set) var values: [CreateTabInterval.Outcome] = []
        var done: @MainActor (CreateTabInterval.Outcome) -> Void { { [self] in values.append($0) } }
    }

    @Test func contentThatAwaitsItsFirstPaintShowsAtThatPaintOnce() {
        let gated = Gated(painted: false)
        let outcomes = Outcomes()
        let firstFrame = gated.createTabFirstFrame(content: gated)
        // Compared before #expect: its expansion of `===` over AnyObject? and Gated crashes SILGen (Swift 6.3.3).
        let isGated = firstFrame.content === gated
        #expect(isGated)
        _ = firstFrame.wait(outcomes.done)
        #expect(outcomes.values.isEmpty)
        gated.paint()
        gated.paint()
        #expect(outcomes.values == [.shown])
    }

    @Test func contentThatPaintedAlreadyShowsInTheWaitsCall() {
        let gated = Gated(painted: true)
        let outcomes = Outcomes()
        _ = gated.createTabFirstFrame(content: gated).wait(outcomes.done)
        #expect(outcomes.values == [.shown])
    }
}
