import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator agent cursor")
struct SimulatorAgentCursorTests {
    @Test("Cursor plans recover displayed points from raw landscape HID input")
    func planUsesDisplayedCoordinates() throws {
        let display = SimulatorDisplayMetadata(
            width: 400,
            height: 800,
            orientation: .landscapeRight,
            scale: 3
        )
        let geometry = SimulatorOrientationGeometry(display: display)
        let displayed = SimulatorPoint(x: 0.24, y: 0.61)
        let raw = geometry.rawPoint(for: displayed)
        let plan = try #require(simulatorAgentCursorPlan(
            for: .interactive(.gesture([
                SimulatorPointerEvent(phase: .began, primary: raw),
                SimulatorPointerEvent(phase: .ended, primary: raw),
            ])),
            display: display
        ))

        #expect(plan.origin == displayed)
        #expect(plan.destination == displayed)
        #expect(plan.durationMilliseconds == 50)
        #expect(plan.beginsTouch)
        #expect(plan.completionPhase == .clicked)
    }

    @Test("Timed gestures preserve worker duration and endpoints")
    func timedGesturePlan() throws {
        let start = SimulatorPoint(x: 0.2, y: 0.8)
        let end = SimulatorPoint(x: 0.2, y: 0.3)
        let plan = try #require(simulatorAgentCursorPlan(
            for: .interactive(.timedGesture(
                events: [
                    SimulatorPointerEvent(phase: .began, primary: start),
                    SimulatorPointerEvent(phase: .ended, primary: end),
                ],
                durationMilliseconds: 640
            )),
            display: nil
        ))

        #expect(plan.origin == start)
        #expect(plan.destination == end)
        #expect(plan.durationMilliseconds == 640)
        #expect(plan.completionPhase == .clicked)
    }

    @Test("Cursor state is isolated to the targeted panel coordinator")
    func panelIsolation() async throws {
        let target = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        let neighbor = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        let point = SimulatorPoint(x: 0.35, y: 0.72)

        _ = try await target.perform(.interactive(.gesture([
            SimulatorPointerEvent(phase: .began, primary: point),
            SimulatorPointerEvent(phase: .ended, primary: point),
        ])))

        #expect(target.agentCursorPresentation?.destination == point)
        #expect(target.agentCursorPresentation?.phase == .clicked)
        #expect(neighbor.agentCursorPresentation == nil)
    }

    @Test("A down-only touch stays pressed until its matching release")
    func heldTouchLifecycle() async throws {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        let point = SimulatorPoint(x: 0.5, y: 0.5)

        _ = try await coordinator.perform(.interactive(.touch(
            events: [SimulatorPointerEvent(phase: .began, primary: point)],
            holdMilliseconds: 0
        )))
        #expect(coordinator.agentCursorPresentation?.phase == .pressed)

        _ = try await coordinator.perform(.interactive(.touch(
            events: [SimulatorPointerEvent(phase: .ended, primary: point)],
            holdMilliseconds: 0
        )))
        #expect(coordinator.agentCursorPresentation?.phase == .clicked)
    }

    @Test("Keyboard actions never create a pointer cursor")
    func keyboardDoesNotCreateCursor() async throws {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )

        _ = try await coordinator.perform(.interactive(.keyPresses(
            usages: [40],
            pressDurationMilliseconds: 50,
            interKeyDelayMilliseconds: 0
        )))

        #expect(coordinator.agentCursorPresentation == nil)
    }
}
