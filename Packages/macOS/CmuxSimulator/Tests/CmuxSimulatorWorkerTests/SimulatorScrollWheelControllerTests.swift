import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Worker-paced Simulator wheel bursts")
struct SimulatorScrollWheelControllerTests {
    @Test("Wheel deltas share one touch until cancellation ends the burst")
    @MainActor
    func coalescesDeltasAndCancels() async {
        let sleeper = BlockingWheelIdleSleeper()
        var events: [SimulatorPointerEvent] = []
        var completions: [UUID] = []
        let controller = SimulatorScrollWheelController(
            sender: { events.append($0); return true },
            sleeper: sleeper,
            completion: { completions.append($0) }
        )
        let first = SimulatorScrollWheelEvent(
            anchor: SimulatorPoint(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 0.1
        )
        let second = SimulatorScrollWheelEvent(
            anchor: SimulatorPoint(x: 0.6, y: 0.6),
            deltaX: 0,
            deltaY: 0.1
        )

        #expect(await controller.send(first))
        #expect(await controller.send(second))
        #expect(events.map(\.phase) == [.began, .moved, .moved])
        #expect(completions.isEmpty)
        #expect(controller.cancel())
        #expect(events.last?.phase == .cancelled)
        #expect(completions == [second.id])
        #expect(sleeper.durations.filter { $0 == .milliseconds(8) }.count == 1)
    }

    @Test("Idle completion ends the touch after the bounded burst delay")
    @MainActor
    func endsAfterIdleDelay() async {
        let sleeper = ImmediateWheelSleeper()
        var events: [SimulatorPointerEvent] = []
        var completions: [UUID] = []
        let controller = SimulatorScrollWheelController(
            sender: { events.append($0); return true },
            sleeper: sleeper,
            completion: { completions.append($0) }
        )
        let event = SimulatorScrollWheelEvent(
            anchor: SimulatorPoint(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 0.1
        )

        #expect(await controller.send(event))
        for _ in 0..<1_000 where completions.isEmpty { await Task.yield() }

        #expect(events.map(\.phase) == [.began, .moved, .ended])
        #expect(completions == [event.id])
        #expect(sleeper.durations == [.milliseconds(8), .milliseconds(100)])
    }

    @Test("A failed touch termination keeps host recovery armed")
    @MainActor
    func failedCancellationDoesNotComplete() async {
        let sleeper = BlockingWheelIdleSleeper()
        var events: [SimulatorPointerEvent] = []
        var completions: [UUID] = []
        let controller = SimulatorScrollWheelController(
            sender: {
                events.append($0)
                return $0.phase != .cancelled
            },
            sleeper: sleeper,
            completion: { completions.append($0) }
        )
        let event = SimulatorScrollWheelEvent(
            anchor: SimulatorPoint(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 0.1
        )

        #expect(await controller.send(event))
        #expect(!controller.cancel())
        #expect(events.last?.phase == .cancelled)
        #expect(completions.isEmpty)
    }

    @Test("Rejected wheel input completes immediately when no touch was accepted")
    @MainActor
    func rejectedBeginCompletes() async {
        var completions: [UUID] = []
        let controller = SimulatorScrollWheelController(
            sender: { _ in false },
            sleeper: ImmediateWheelSleeper(),
            completion: { completions.append($0) }
        )
        let event = SimulatorScrollWheelEvent(
            anchor: SimulatorPoint(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 0.1
        )

        #expect(!(await controller.send(event)))
        #expect(completions == [event.id])
    }
}
