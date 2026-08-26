import Foundation
import Testing

@testable import CmuxSimulatorStreamKit

@Suite
struct SimStreamCreditGateTests {
    @Test
    func windowBoundsInFlightFrames() {
        var gate = SimStreamCreditGate(window: 2)
        #expect(gate.hasCredit)
        #expect(gate.consumeCredit() == 1)
        #expect(gate.hasCredit)
        #expect(gate.consumeCredit() == 2)
        #expect(!gate.hasCredit)

        gate.acknowledge(1)
        #expect(gate.hasCredit)
        #expect(gate.consumeCredit() == 3)
        #expect(!gate.hasCredit)
    }

    @Test
    func cumulativeAckReleasesEverythingUpToSequence() {
        var gate = SimStreamCreditGate(window: 3)
        _ = gate.consumeCredit()
        _ = gate.consumeCredit()
        _ = gate.consumeCredit()
        gate.acknowledge(3)
        #expect(gate.unacknowledgedCount == 0)
    }

    @Test
    func bogusAcksNeverMintCredit() {
        var gate = SimStreamCreditGate(window: 1)
        _ = gate.consumeCredit()
        gate.acknowledge(99)  // never sent
        #expect(!gate.hasCredit)
        gate.acknowledge(0)  // regression
        #expect(!gate.hasCredit)
        gate.acknowledge(1)
        #expect(gate.hasCredit)

        // Duplicate ack after restart cannot double-release.
        _ = gate.consumeCredit()
        gate.acknowledge(1)
        #expect(!gate.hasCredit)
    }

    @Test
    func resetInFlightRestoresCreditWithoutReusingSequences() {
        var gate = SimStreamCreditGate(window: 2)
        _ = gate.consumeCredit()
        _ = gate.consumeCredit()
        gate.resetInFlight()
        #expect(gate.hasCredit)
        #expect(gate.consumeCredit() == 3)
    }
}

@Suite
struct SimStreamBitrateControllerTests {
    @Test
    func congestionCutsAndRecoveryProbes() {
        var controller = SimStreamBitrateController()
        let initial = controller.targetBitsPerSecond

        // Slow ack cuts the target.
        let cut = controller.recordAck(sendTime: 0, ackTime: 0.5)
        #expect(cut != nil)
        #expect(controller.targetBitsPerSecond < initial)

        // Sustained fast acks eventually raise it again.
        var time = 2.0
        var raised: Int?
        for _ in 0..<60 {
            raised = controller.recordAck(sendTime: time, ackTime: time + 0.01) ?? raised
            time += 0.05
        }
        #expect(raised != nil)
        #expect(controller.targetBitsPerSecond > cut!)
    }

    @Test
    func holdOffRateLimitsChanges() {
        var controller = SimStreamBitrateController()
        let first = controller.recordAck(sendTime: 0, ackTime: 0.5)
        #expect(first != nil)
        // A second congested ack inside the hold-off must not change again.
        let second = controller.recordAck(sendTime: 0.5, ackTime: 1.1)
        #expect(second == nil)
    }

    @Test
    func targetNeverLeavesConfiguredBounds() {
        var controller = SimStreamBitrateController(
            configuration: .init(
                initialBitsPerSecond: 1_000_000,
                minimumBitsPerSecond: 800_000,
                maximumBitsPerSecond: 1_200_000,
                holdOff: 0
            ))
        var time = 0.0
        for _ in 0..<20 {
            _ = controller.recordAck(sendTime: time, ackTime: time + 10)
            time += 20
        }
        #expect(controller.targetBitsPerSecond == 800_000)
        for _ in 0..<2000 {
            _ = controller.recordAck(sendTime: time, ackTime: time + 0.001)
            time += 0.05
        }
        #expect(controller.targetBitsPerSecond == 1_200_000)
    }
}

@Suite
struct SimStreamInputOutboxTests {
    private func touch(
        _ phase: SimStreamTouchPhase, pointer: UInt8 = 0, x: Float = 0.5, y: Float = 0.5,
        at time: UInt64 = 0
    ) -> SimStreamInputEvent {
        .touch(phase: phase, pointerID: pointer, x: x, y: y, timestampMicroseconds: time)
    }

    @Test
    func movesCoalescePerPointerWhilePending() {
        var outbox = SimStreamInputOutbox()
        outbox.enqueue(touch(.began, at: 1))
        outbox.enqueue(touch(.moved, x: 0.1, at: 2))
        outbox.enqueue(touch(.moved, x: 0.2, at: 3))
        outbox.enqueue(touch(.moved, pointer: 1, x: 0.9, at: 4))
        outbox.enqueue(touch(.moved, x: 0.3, at: 5))
        outbox.enqueue(touch(.ended, x: 0.3, at: 6))

        let batch = outbox.drainBatch()
        #expect(
            batch?.events == [
                touch(.began, at: 1),
                touch(.moved, x: 0.3, at: 5),
                touch(.moved, pointer: 1, x: 0.9, at: 4),
                touch(.ended, x: 0.3, at: 6),
            ])
    }

    @Test
    func downAndUpNeverCoalesceAndOrderIsPreservedAcrossKinds() {
        var outbox = SimStreamInputOutbox()
        outbox.enqueue(touch(.began, at: 1))
        outbox.enqueue(touch(.ended, at: 2))
        outbox.enqueue(touch(.began, at: 3))
        outbox.enqueue(touch(.moved, x: 0.6, at: 4))
        outbox.enqueue(SimStreamInputEvent.text("a"))
        // A move after a non-move barrier must not merge backward past it.
        outbox.enqueue(touch(.moved, x: 0.7, at: 5))
        outbox.enqueue(touch(.ended, at: 6))

        let batch = outbox.drainBatch()
        #expect(
            batch?.events == [
                touch(.began, at: 1),
                touch(.ended, at: 2),
                touch(.began, at: 3),
                touch(.moved, x: 0.6, at: 4),
                .text("a"),
                touch(.moved, x: 0.7, at: 5),
                touch(.ended, at: 6),
            ])
    }

    @Test
    func batchSequencesAreMonotonicAcrossDrains() {
        var outbox = SimStreamInputOutbox()
        outbox.enqueue(touch(.began))
        let first = outbox.drainBatch()
        outbox.enqueue(touch(.ended))
        let second = outbox.drainBatch()
        #expect(first?.sequence == 1)
        #expect(second?.sequence == 2)
        #expect(outbox.drainBatch() == nil)
    }

    @Test
    func sequenceGuardRejectsReplayAndRegression() {
        var sequenceGuard = SimStreamInputSequenceGuard()
        let one = SimStreamInputBatch(sequence: 1, events: [])
        let two = SimStreamInputBatch(sequence: 2, events: [])
        let acceptsOne = sequenceGuard.shouldApply(one)
        let acceptsTwo = sequenceGuard.shouldApply(two)
        let acceptsTwoAgain = sequenceGuard.shouldApply(two)
        let acceptsOneReplay = sequenceGuard.shouldApply(one)
        #expect(acceptsOne)
        #expect(acceptsTwo)
        #expect(!acceptsTwoAgain)
        #expect(!acceptsOneReplay)
    }
}

@Suite
struct SimStreamViewerLifecycleTests {
    @Test
    func happyPathActivatesThroughTransportToStreaming() {
        var lifecycle = SimStreamViewerLifecycle()
        #expect(lifecycle.handle(.activate) == .none)
        #expect(lifecycle.phase == .waitingForTransport)
        #expect(lifecycle.handle(.transportReady) == .openLaneAndStart)
        #expect(lifecycle.handle(.startSucceeded) == .none)
        #expect(lifecycle.phase == .streaming)
    }

    @Test
    func everyWedgeFunnelsIntoRetryWithBackoff() {
        var lifecycle = SimStreamViewerLifecycle()
        _ = lifecycle.handle(.activate)
        _ = lifecycle.handle(.transportReady)
        _ = lifecycle.handle(.startSucceeded)

        guard case .teardownAndRetry(let firstDelay) =
            lifecycle.handle(.streamWedged(reason: "decode failures"))
        else {
            Issue.record("expected retry")
            return
        }
        #expect(lifecycle.handle(.retryDelayElapsed) == .none)
        #expect(lifecycle.handle(.transportReady) == .openLaneAndStart)

        guard case .teardownAndRetry(let secondDelay) = lifecycle.handle(.transportLost) else {
            Issue.record("expected retry")
            return
        }
        #expect(secondDelay > firstDelay)
    }

    @Test
    func framePresentedResetsBackoff() {
        var lifecycle = SimStreamViewerLifecycle()
        _ = lifecycle.handle(.activate)
        _ = lifecycle.handle(.transportReady)
        _ = lifecycle.handle(.startSucceeded)
        _ = lifecycle.handle(.streamWedged(reason: "x"))
        _ = lifecycle.handle(.retryDelayElapsed)
        _ = lifecycle.handle(.transportReady)
        _ = lifecycle.handle(.startSucceeded)
        _ = lifecycle.handle(.framePresented)

        guard case .teardownAndRetry(let delay) = lifecycle.handle(.transportLost) else {
            Issue.record("expected retry")
            return
        }
        #expect(delay == 0.25)  // backoff restarted from the base
    }

    @Test
    func backgroundTearsDownAndForegroundReattaches() {
        var lifecycle = SimStreamViewerLifecycle()
        _ = lifecycle.handle(.activate)
        _ = lifecycle.handle(.transportReady)
        _ = lifecycle.handle(.startSucceeded)
        #expect(lifecycle.handle(.appBackgrounded) == .teardown)
        #expect(lifecycle.phase == .backgrounded)
        #expect(lifecycle.handle(.appForegrounded) == .none)
        #expect(lifecycle.phase == .waitingForTransport)
        #expect(lifecycle.handle(.transportReady) == .openLaneAndStart)
    }

    @Test
    func hostEndedIsTerminalUntilReactivation() {
        var lifecycle = SimStreamViewerLifecycle()
        _ = lifecycle.handle(.activate)
        _ = lifecycle.handle(.transportReady)
        _ = lifecycle.handle(.startSucceeded)
        #expect(
            lifecycle.handle(.hostEnded(status: .closed, detail: "panel closed")) == .teardown)
        // No self-retry into a closed panel.
        #expect(lifecycle.handle(.transportReady) == .none)
        #expect(lifecycle.handle(.retryDelayElapsed) == .none)
        // Explicit reactivation works again.
        #expect(lifecycle.handle(.activate) == .none)
        #expect(lifecycle.handle(.transportReady) == .openLaneAndStart)
    }

    @Test
    func deactivateFromAnyActivePhaseTearsDown() {
        var lifecycle = SimStreamViewerLifecycle()
        _ = lifecycle.handle(.activate)
        _ = lifecycle.handle(.transportReady)
        #expect(lifecycle.handle(.deactivate) == .teardown)
        #expect(lifecycle.phase == .stopped)
        #expect(lifecycle.handle(.deactivate) == .none)
    }
}
