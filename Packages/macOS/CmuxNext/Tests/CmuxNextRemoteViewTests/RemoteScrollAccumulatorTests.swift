import AppKit
import CmuxNextRemoteView
import Testing

@Suite struct RemoteScrollAccumulatorTests {
    @Test func fractionalDeltasAccumulateUntilTheyReachOneWireUnit() {
        var accumulator = RemoteScrollAccumulator()

        #expect(accumulator.add(deltaX: 0.004, deltaY: 0, precise: true, phase: [], momentumPhase: []) == nil)
        #expect(accumulator.add(deltaX: 0.006, deltaY: 0, precise: true, phase: [], momentumPhase: []) == .scroll(dx: 1, dy: 0, precise: true))
    }

    @Test func beginningAGestureDropsThePreviousRemainder() {
        var accumulator = RemoteScrollAccumulator()

        #expect(accumulator.add(deltaX: 0.009, deltaY: 0, precise: false, phase: [], momentumPhase: []) == nil)
        #expect(accumulator.add(deltaX: 0.002, deltaY: 0, precise: false, phase: [.began], momentumPhase: []) == nil)
        #expect(accumulator.add(deltaX: 0.008, deltaY: 0, precise: false, phase: [], momentumPhase: []) == .scroll(dx: 1, dy: 0, precise: false))
    }

    @Test func momentumBeginningAlsoDropsThePreviousRemainder() {
        var accumulator = RemoteScrollAccumulator()

        #expect(accumulator.add(deltaX: 0.009, deltaY: 0, precise: true, phase: [], momentumPhase: []) == nil)
        #expect(accumulator.add(deltaX: 0.002, deltaY: 0, precise: true, phase: [], momentumPhase: [.began]) == nil)
        #expect(accumulator.add(deltaX: 0.008, deltaY: 0, precise: true, phase: [], momentumPhase: []) == .scroll(dx: 1, dy: 0, precise: true))
    }

    @Test func endedGestureClearsRemainderBeforeTheNextGesture() {
        var accumulator = RemoteScrollAccumulator()

        #expect(accumulator.add(deltaX: 0.009, deltaY: 0, precise: true, phase: [.ended], momentumPhase: []) == nil)
        #expect(accumulator.add(deltaX: 0.002, deltaY: 0, precise: true, phase: [], momentumPhase: []) == nil)
        #expect(accumulator.add(deltaX: 0.008, deltaY: 0, precise: true, phase: [], momentumPhase: []) == .scroll(dx: 1, dy: 0, precise: true))
    }

    @Test func largeDeltasAreClampedToTheWireIntegerRange() {
        var accumulator = RemoteScrollAccumulator()

        #expect(accumulator.add(deltaX: Double(Int32.max) * 2, deltaY: Double(Int32.min) * 2, precise: false, phase: [], momentumPhase: []) == .scroll(dx: Int32.max, dy: Int32.min, precise: false))
    }
}
