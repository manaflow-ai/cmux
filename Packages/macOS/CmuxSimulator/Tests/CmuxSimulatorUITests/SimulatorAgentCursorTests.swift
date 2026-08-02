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
        let plan = try #require(SimulatorAgentCursorPlan(
            action: .interactive(.gesture([
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
        let plan = try #require(SimulatorAgentCursorPlan(
            action: .interactive(.timedGesture(
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

    @Test("A live display initializes an always-visible resting cursor")
    func displayInitializesRestingCursor() {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )

        coordinator.receive(.message(.display(SimulatorDisplayMetadata(
            width: 1_200,
            height: 2_400,
            orientation: .portrait,
            scale: 3
        ))))

        #expect(coordinator.agentCursorPresentation?.origin == SimulatorPoint(x: 0.5, y: 0.5))
        #expect(coordinator.agentCursorPresentation?.destination == SimulatorPoint(x: 0.5, y: 0.5))
        #expect(coordinator.agentCursorPresentation != nil)
    }

    @Test("The last agent cursor persists through non-pointer actions")
    func lastCursorPersists() async throws {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        let point = SimulatorPoint(x: 0.31, y: 0.68)

        _ = try await coordinator.perform(.interactive(.gesture([
            SimulatorPointerEvent(phase: .began, primary: point),
            SimulatorPointerEvent(phase: .ended, primary: point),
        ])))
        let cursor = try #require(coordinator.agentCursorPresentation)

        _ = try await coordinator.perform(.interactive(.keyPresses(
            usages: [40],
            pressDurationMilliseconds: 50,
            interKeyDelayMilliseconds: 0
        )))

        #expect(coordinator.agentCursorPresentation == cursor)
    }

    @Test("Consecutive taps travel from the last visible cursor position")
    func consecutiveTapsUseLastPosition() async throws {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        let first = SimulatorPoint(x: 0.2, y: 0.3)
        let second = SimulatorPoint(x: 0.8, y: 0.7)

        _ = try await coordinator.perform(.interactive(.gesture([
            SimulatorPointerEvent(phase: .began, primary: first),
            SimulatorPointerEvent(phase: .ended, primary: first),
        ])))
        _ = try await coordinator.perform(.interactive(.gesture([
            SimulatorPointerEvent(phase: .began, primary: second),
            SimulatorPointerEvent(phase: .ended, primary: second),
        ])))

        #expect(coordinator.agentCursorPresentation?.origin == first)
        #expect(coordinator.agentCursorPresentation?.destination == second)
    }

    @Test("A distant tap delays its click phase until cursor travel finishes")
    func distantTapDelaysClickedPhase() async throws {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        coordinator.ensureAgentCursorPresentation()
        let destination = SimulatorPoint(x: 1, y: 1)

        _ = try await coordinator.perform(.interactive(.gesture([
            SimulatorPointerEvent(phase: .began, primary: destination),
            SimulatorPointerEvent(phase: .ended, primary: destination),
        ])))

        let presentation = try #require(coordinator.agentCursorPresentation)
        #expect(presentation.durationMilliseconds == 323)
        #expect(presentation.phase == .clicked)
        #expect(presentation.clickPhaseDelayMilliseconds == 273)
    }

    @Test("HID dispatch waits for the cursor to reach a timed gesture origin")
    func cursorReachesGestureOriginBeforeInputDispatch() async throws {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.ensureAgentCursorPresentation()
        let origin = SimulatorPoint(x: 0.9, y: 0.9)
        let destination = SimulatorPoint(x: 0.1, y: 0.1)
        let action = SimulatorControlAction.interactive(.timedGesture(
            events: [
                SimulatorPointerEvent(phase: .began, primary: origin),
                SimulatorPointerEvent(phase: .ended, primary: destination),
            ],
            durationMilliseconds: 400
        ))

        let operation = Task { @MainActor in
            try await coordinator.perform(action)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await client.actions().isEmpty)
        #expect(coordinator.agentCursorPresentation?.destination == origin)

        _ = try await operation.value
        #expect(await client.actions() == [action])
        await coordinator.close()
    }

    @Test("A selection change during cursor travel prevents HID dispatch")
    func selectionChangeDuringCursorTravelPreventsInputDispatch() async throws {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        coordinator.ensureAgentCursorPresentation()
        let point = SimulatorPoint(x: 0.9, y: 0.9)
        let action = SimulatorControlAction.interactive(.gesture([
            SimulatorPointerEvent(phase: .began, primary: point),
            SimulatorPointerEvent(phase: .ended, primary: point),
        ]))

        let operation = Task { @MainActor in
            try await coordinator.perform(action)
        }
        try await Task.sleep(for: .milliseconds(50))
        coordinator.selectionGeneration &+= 1

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(await client.actions().isEmpty)
        await coordinator.close()
    }

    @Test("A device reattachment preserves the workspace cursor")
    func reattachmentPreservesCursor() async throws {
        let device = SimulatorDevice(
            id: "phone",
            name: "Phone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS",
            deviceTypeIdentifier: "type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorPaneClientSpy(devices: [device])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let point = SimulatorPoint(x: 0.4, y: 0.6)
        _ = try await coordinator.perform(.interactive(.gesture([
            SimulatorPointerEvent(phase: .began, primary: point),
            SimulatorPointerEvent(phase: .ended, primary: point),
        ])))

        try await coordinator.selectDeviceAndWait(id: device.id)

        #expect(coordinator.agentCursorPresentation?.destination == point)
    }

    @Test("Selecting a different device resets the workspace cursor")
    func deviceSwitchResetsCursor() async throws {
        let first = SimulatorDevice(
            id: "phone-1",
            name: "Phone 1",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS",
            deviceTypeIdentifier: "type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let second = SimulatorDevice(
            id: "phone-2",
            name: "Phone 2",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS",
            deviceTypeIdentifier: "type",
            family: .iPhone,
            state: .shutdown,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorPaneClientSpy(devices: [first, second])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        try await coordinator.selectDeviceAndWait(id: first.id)
        let point = SimulatorPoint(x: 0.25, y: 0.75)
        _ = try await coordinator.perform(.interactive(.gesture([
            SimulatorPointerEvent(phase: .began, primary: point),
            SimulatorPointerEvent(phase: .ended, primary: point),
        ])))

        try await coordinator.selectDeviceAndWait(id: second.id)

        #expect(coordinator.agentCursorPresentation == nil)
        coordinator.receive(.message(.display(SimulatorDisplayMetadata(
            width: 1_200,
            height: 2_400,
            orientation: .portrait,
            scale: 3
        ))))
        #expect(coordinator.agentCursorPresentation?.destination == SimulatorPoint(x: 0.5, y: 0.5))
    }
}
