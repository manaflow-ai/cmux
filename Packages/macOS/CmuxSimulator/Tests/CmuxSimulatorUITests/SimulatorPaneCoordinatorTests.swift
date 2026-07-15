import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane coordinator")
@MainActor
struct SimulatorPaneCoordinatorTests {
    @Test("Discovery filters unavailable and non-mobile devices")
    func discoveryFiltering() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
            Self.device(id: "pad", family: .iPad, state: .shutdown),
            Self.device(id: "watch", family: .watch, state: .booted),
            Self.device(id: "missing", family: .iPhone, state: .shutdown, isAvailable: false),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)

        await coordinator.start()

        #expect(coordinator.devices.map { $0.id } == ["phone", "pad"])
        #expect(coordinator.selectedDeviceID == "phone")
    }

    @Test("Worker events update live state and crashes preserve the host")
    func workerEventState() async {
        let client = SimulatorPaneClientSpy(devices: [Self.device(id: "phone", family: .iPhone, state: .booted)])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        await client.emit(SimulatorWorkerEvent.message(.capabilities([.framebuffer, .touch])))
        let frameTransport = simulatorFrameTransportDescriptor(42)
        await client.emit(SimulatorWorkerEvent.message(.frameTransport(frameTransport)))
        await client.emit(SimulatorWorkerEvent.message(.status(.streaming)))
        await eventually {
            coordinator.frameTransport == frameTransport
                && coordinator.status == SimulatorSessionStatus.streaming
        }

        #expect(coordinator.capabilities == Set([
            SimulatorCapability.framebuffer,
            .touch,
            .userInterfaceSettings,
        ]))

        await client.emit(SimulatorWorkerEvent.workerStopped)
        await eventually { coordinator.status == SimulatorSessionStatus.workerCrashed }

        #expect(coordinator.frameTransport == nil)
    }

    @Test("Selection delegates boot and attachment to the client")
    func deviceActivation() async {
        let client = SimulatorPaneClientSpy(devices: [Self.device(id: "pad", family: .iPad, state: .shutdown)])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        coordinator.updateGeometry(SimulatorSurfaceGeometry(width: 640, height: 800, scale: 2))
        coordinator.selectDevice(id: "pad")

        await eventually {
            await client.activations().last?.geometry
                == SimulatorSurfaceGeometry(width: 640, height: 800, scale: 2)
        }
        let activations = await client.activations()
        #expect(activations.last?.id == "pad")
        #expect(activations.last?.geometry == SimulatorSurfaceGeometry(width: 640, height: 800, scale: 2))
    }

    @Test("A new pane establishes portrait orientation after attachment")
    func newPaneEstablishesPortraitOrientation() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)

        await coordinator.start()
        await eventually {
            await client.messages().contains(.rotate(.portrait))
        }

        let messages = await client.messages()
        #expect(messages.filter { $0 == .rotate(.portrait) }.count == 1)
    }

    @Test("Hidden panes suspend and resume framebuffer publication")
    func frameVisibility() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await eventually { coordinator.status == .streaming }
        await client.emit(.message(.frameTransport(simulatorFrameTransportDescriptor(49))))
        await eventually { coordinator.frameTransport != nil }

        coordinator.setFrameVisibility(false)
        await eventually {
            await client.messages().contains(.setFramebufferPublishing(false))
        }
        #expect(coordinator.frameTransport == nil)

        coordinator.setFrameVisibility(true)
        await eventually {
            await client.messages().contains(.setFramebufferPublishing(true))
        }
    }

    @Test("Explicit recovery returns only after the selected device streams")
    func explicitRecoveryWaitsForActivation() async throws {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()

        try await coordinator.recoverAndWait()

        #expect(coordinator.status == .streaming)
        #expect(await client.activations().map(\.id) == ["phone"])
    }

    @Test("Explicit device selection waits for the requested iPad")
    func explicitDeviceSelection() async throws {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
            Self.device(id: "pad", family: .iPad, state: .shutdown),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()

        try await coordinator.selectDeviceAndWait(id: "pad")

        #expect(coordinator.selectedDeviceID == "pad")
        #expect(coordinator.status == .streaming)
        #expect(await client.activations().last?.id == "pad")
    }

    @Test("Swipe commands stay ordered on one outbox")
    func swipeOrdering() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        coordinator.swipe(
            from: SimulatorPoint(x: 0.5, y: 0.9),
            to: SimulatorPoint(x: 0.5, y: 0.1),
            edge: .bottom
        )

        await eventually { await client.messages().count == 8 }
        let phases = await client.messages().compactMap { message -> SimulatorTouchPhase? in
            guard case let .pointer(event) = message else { return nil }
            return event.phase
        }
        #expect(phases == [.began, .moved, .moved, .moved, .moved, .moved, .moved, .ended])
    }

    @Test("Text validates completely and resolves only the matching worker completion")
    func correlatedTextInput() async throws {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await client.emit(.message(.capabilities([.keyboard])))
        await client.emit(.message(.status(.streaming)))
        await eventually { coordinator.status == .streaming && coordinator.supports(.keyboard) }

        #expect(coordinator.typeText("a🙂") == .failure(.encoding(.unsupportedScalar(
            value: 0x1F642,
            scalarIndex: 1
        ))))
        let oversized = String(
            repeating: "a",
            count: SimulatorTextInputSequence.maximumUTF8ByteCount + 1
        )
        guard case .failure(.encoding(.tooLong)) = coordinator.typeText(oversized) else {
            Issue.record("Expected oversize validation failure")
            return
        }
        #expect(await client.messages().allSatisfy { message in
            if case .typeText = message { return false }
            return true
        })

        let completions = LockedTextInputCompletions()
        let submission = coordinator.beginTypeText("A?", completion: { succeeded in
            completions.append(succeeded)
        })
        guard case let .success(submitted) = submission else {
            Issue.record("Expected text submission")
            return
        }
        #expect(submitted.characterCount == 2)
        await eventually {
            await client.messages().contains { if case .typeText = $0 { true } else { false } }
        }
        let message = try #require(await client.messages().first { message in
            if case .typeText = message { return true }
            return false
        })
        guard case let .typeText(requestID, sequence) = message else { return }
        #expect(sequence == (try SimulatorUSKeyboardTextEncoder().encode("A?")))

        await client.emit(.message(.textInput(requestID: UUID(), succeeded: true)))
        await Task.yield()
        #expect(completions.values().isEmpty)

        await client.emit(.message(.textInput(requestID: requestID, succeeded: true)))
        await eventually { completions.values() == [true] }
    }

    @Test("Worker teardown fails a pending text receipt exactly once")
    func textInputTeardown() async {
        let client = SimulatorPaneClientSpy(devices: [])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await client.emit(.message(.capabilities([.keyboard])))
        await client.emit(.message(.status(.streaming)))
        await eventually { coordinator.status == .streaming && coordinator.supports(.keyboard) }

        let completions = LockedTextInputCompletions()
        let submission = coordinator.beginTypeText("retry", completion: { succeeded in
            completions.append(succeeded)
        })
        guard case let .success(submitted) = submission else {
            Issue.record("Expected text submission")
            return
        }
        #expect(submitted.characterCount == 5)
        await client.emit(.workerStopped)
        await client.emit(.workerStopped)
        await eventually { completions.values() == [false] }
    }

    @Test("Persistence falls back from UDID to the newest matching device type")
    func persistenceFallback() async {
        let older = Self.device(
            id: "older",
            family: .iPhone,
            state: .shutdown,
            runtimeIdentifier: "runtime-26",
            deviceTypeIdentifier: "phone-pro",
            lastBootedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = Self.device(
            id: "newer",
            family: .iPhone,
            state: .shutdown,
            runtimeIdentifier: "runtime-26",
            deviceTypeIdentifier: "phone-pro",
            lastBootedAt: Date(timeIntervalSince1970: 20)
        )
        let client = SimulatorPaneClientSpy(devices: [older, newer])
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            preferredDeviceID: "deleted-device",
            preferredRuntimeIdentifier: "runtime-26",
            preferredDeviceTypeIdentifier: "phone-pro"
        )

        await coordinator.start()

        #expect(coordinator.selectedDeviceID == "newer")
        #expect(coordinator.selectedDevice?.deviceTypeIdentifier == "phone-pro")
    }

    @Test("Closing joins activation and prevents later worker restarts")
    func closeIsTerminal() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "one", family: .iPhone, state: .booted),
            Self.device(id: "two", family: .iPad, state: .shutdown),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await eventually { await client.activations().count == 1 }

        await coordinator.close()
        coordinator.selectDevice(id: "two")
        await coordinator.start()
        await Task.yield()

        #expect(await client.activations().count == 1)
        #expect(await client.stopCount() == 1)
    }

    @Test("Dropped apps and media route through typed native actions")
    func droppedFiles() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        await coordinator.importDroppedFiles([
            URL(fileURLWithPath: "/tmp/Fixture.app"),
            URL(fileURLWithPath: "/tmp/photo.png"),
            URL(fileURLWithPath: "/tmp/photo.heif"),
            URL(fileURLWithPath: "/tmp/photo.webp"),
            URL(fileURLWithPath: "/tmp/notes.txt"),
        ])

        let actions = await client.actions()
        #expect(actions.contains(.installApplication(
            deviceID: "phone",
            applicationURL: URL(fileURLWithPath: "/tmp/Fixture.app")
        )))
        #expect(actions.contains(.addMedia(
            deviceID: "phone",
            urls: [
                URL(fileURLWithPath: "/tmp/photo.png"),
                URL(fileURLWithPath: "/tmp/photo.heif"),
                URL(fileURLWithPath: "/tmp/photo.webp"),
            ]
        )))
        #expect(!actions.contains(.addMedia(
            deviceID: "phone",
            urls: [URL(fileURLWithPath: "/tmp/notes.txt")]
        )))
    }

    @Test("Recoverable tool failures keep a live display interactive")
    func recoverableToolFailure() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        let frameTransport = simulatorFrameTransportDescriptor(42)
        await client.emit(.message(.frameTransport(frameTransport)))
        await client.emit(.message(.status(.streaming)))
        await client.emit(.message(.failure(SimulatorFailure(
            code: "unsupported_tool",
            message: "Unsupported",
            isRecoverable: true
        ))))
        await eventually { coordinator.controlFailure?.code == "unsupported_tool" }

        #expect(coordinator.status == .streaming)
        #expect(coordinator.frameTransport == frameTransport)
    }

    @Test("Closing disables an active injected camera before stopping the client")
    func closeDisablesCamera() async {
        let client = SimulatorPaneClientSpy(devices: [
            Self.device(id: "phone", family: .iPhone, state: .booted),
        ])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.useCameraPlaceholder()

        await coordinator.close()

        let actions = await client.actions()
        #expect(actions.contains(.configureCamera(.disabled)))
        #expect(await client.stopCount() == 1)
    }

    func eventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }

    static func device(
        id: String,
        family: SimulatorDeviceFamily,
        state: SimulatorDeviceState,
        isAvailable: Bool = true,
        runtimeIdentifier: String = "runtime",
        deviceTypeIdentifier: String = "type",
        lastBootedAt: Date? = nil
    ) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: id,
            runtimeIdentifier: runtimeIdentifier,
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: deviceTypeIdentifier,
            family: family,
            state: state,
            isAvailable: isAvailable,
            lastBootedAt: lastBootedAt
        )
    }

    static func application(id: String, type: String) -> SimulatorInstalledApplication {
        SimulatorInstalledApplication(
            id: id,
            name: id,
            displayName: id,
            executableName: id,
            path: "/Applications/\(id).app",
            applicationType: type
        )
    }
}
