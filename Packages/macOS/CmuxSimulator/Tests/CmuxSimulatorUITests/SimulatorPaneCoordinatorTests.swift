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
        await client.emit(SimulatorWorkerEvent.message(.context(42)))
        await client.emit(SimulatorWorkerEvent.message(.status(.streaming)))
        await eventually { coordinator.contextID == 42 && coordinator.status == SimulatorSessionStatus.streaming }

        #expect(coordinator.capabilities == Set([
            SimulatorCapability.framebuffer,
            .touch,
            .userInterfaceSettings,
        ]))

        await client.emit(SimulatorWorkerEvent.workerStopped)
        await eventually { coordinator.status == SimulatorSessionStatus.workerCrashed }

        #expect(coordinator.contextID == nil)
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
        #expect(sequence == (try SimulatorUSKeyboardTextEncoder.encode("A?")))

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
        await client.emit(.message(.context(42)))
        await client.emit(.message(.status(.streaming)))
        await client.emit(.message(.failure(SimulatorFailure(
            code: "unsupported_tool",
            message: "Unsupported",
            isRecoverable: true
        ))))
        await eventually { coordinator.controlFailure?.code == "unsupported_tool" }

        #expect(coordinator.status == .streaming)
        #expect(coordinator.contextID == 42)
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

private final class LockedTextInputCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    func append(_ value: Bool) { lock.withLock { storage.append(value) } }
    func values() -> [Bool] { lock.withLock { storage } }
}

actor SimulatorPaneClientSpy: SimulatorPaneClient {
    struct Activation: Sendable {
        let id: String
        let geometry: SimulatorSurfaceGeometry?
    }

    nonisolated let contextCache = SimulatorRemoteContextCache()
    private let devicesValue: [SimulatorDevice]
    private let applicationValues: [SimulatorInstalledApplication]
    private let delaysApplicationList: Bool
    private let eventStream: SimulatorWorkerEventStream
    private let eventContinuation: SimulatorWorkerEventStream.Continuation
    private var sentMessages: [SimulatorWorkerInbound] = []
    private var activationValues: [Activation] = []
    private var stopValue = 0
    private var invalidationValue = 0
    private var actionValues: [SimulatorControlAction] = []
    private var delayedApplicationList: CheckedContinuation<SimulatorControlResult, Never>?

    init(
        devices: [SimulatorDevice],
        applications: [SimulatorInstalledApplication] = [],
        delaysApplicationList: Bool = false
    ) {
        self.devicesValue = devices
        self.applicationValues = applications
        self.delaysApplicationList = delaysApplicationList
        let (stream, continuation) = SimulatorWorkerEventStream.makeStream(
            maximumBufferedBytes: 1_024 * 1_024,
            maximumBufferedEvents: 64,
            onTermination: {}
        )
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        devicesValue
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        activationValues.append(Activation(id: id, geometry: geometry))
    }

    func shutdownDevice(id: String) async throws {}

    func subscribe() async -> SimulatorWorkerEventStream {
        eventStream
    }

    func send(_ message: SimulatorWorkerInbound) async {
        sentMessages.append(message)
    }

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actionValues.append(action)
        if case .listApplications = action {
            if delaysApplicationList {
                return await withCheckedContinuation { delayedApplicationList = $0 }
            }
            return .applications(applicationValues)
        }
        return .none
    }

    func invalidateWorker() async { invalidationValue += 1 }

    func stop() async { stopValue += 1 }

    func emit(_ event: SimulatorWorkerEvent) {
        _ = eventContinuation.yield(event)
    }

    func messages() -> [SimulatorWorkerInbound] {
        sentMessages
    }

    func activations() -> [Activation] {
        activationValues
    }

    func stopCount() -> Int {
        stopValue
    }

    func invalidationCount() -> Int {
        invalidationValue
    }

    func actions() -> [SimulatorControlAction] {
        actionValues
    }

    func hasDelayedApplicationList() -> Bool {
        delayedApplicationList != nil
    }

    func resumeApplicationList(with applications: [SimulatorInstalledApplication]) {
        delayedApplicationList?.resume(returning: .applications(applications))
        delayedApplicationList = nil
    }
}
