import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator worker keyboard activity")
struct SimulatorWorkerKeyboardActivityTests {
    @Test("Ordinary key events do not publish activity rows")
    @MainActor
    func ordinaryKeysStayOffActivityStream() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)
        coordinator.hid = SimulatorHIDTransport(
            frameworkLoader: coordinator.frameworkLoader,
            keySenderOverride: { _ in true }
        )

        #expect(await coordinator.handle(.key(.init(usage: 4, phase: .down))))
        #expect(await coordinator.handle(.key(.init(usage: 4, phase: .up))))
        #expect(await coordinator.handle(.ping(42)))

        #expect(try await fixture.receiveAsync() == .ack(42))
    }

    @Test("Unavailable interactive actions emit one failure and one activity row")
    @MainActor
    func unavailableInteractiveActionHasOneLogEntry() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)

        #expect(!(await coordinator.performInteractiveAction(.hardwareButton(.home))))

        let messages = try fixture.receiveAvailable()
        #expect(messages.count == 2)
        #expect(messages.contains { message in
            if case let .failure(failure) = message {
                return failure.code == "button_unavailable"
            }
            return false
        })
        #expect(messages.filter { message in
            if case .actionLog = message { return true }
            return false
        }.count == 1)
    }

    @Test("Input quiescence confirms ordered release")
    @MainActor
    func inputQuiescenceConfirmsRelease() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)
        var pointerEvents: [SimulatorPointerEvent] = []
        coordinator.scrollWheel = SimulatorScrollWheelController(
            sender: { pointerEvents.append($0); return true },
            sleeper: BlockingWheelIdleSleeper(),
            completion: { eventID in
                coordinator.send(.scrollWheelEnded(eventID: eventID))
            }
        )
        let scroll = SimulatorScrollWheelEvent(
            id: UUID(),
            anchor: SimulatorPoint(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 0.25
        )
        let requestIdentifier = UUID()

        #expect(await coordinator.handle(.scrollWheel(scroll)))
        #expect(pointerEvents.last?.phase == .moved)
        #expect(await coordinator.handle(.quiesceInput(
            requestID: requestIdentifier
        )))

        #expect(pointerEvents.last?.phase == .cancelled)
        #expect(try fixture.receiveAvailable() == [
            .scrollWheelEnded(eventID: scroll.id),
            .inputQuiesced(requestID: requestIdentifier),
        ])
    }
}
