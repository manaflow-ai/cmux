import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane location lifecycle")
@MainActor
struct SimulatorPaneCoordinatorLocationLifecycleTests {
    @Test("Switching from A to B restores A before activating B")
    func deviceSwitchStopsRouteFirst() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A"), Self.device("B")])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await eventually { await client.operations().contains("activate:A") }
        await coordinator.startLocationRoute(Self.route())

        coordinator.selectDevice(id: "B")
        await eventually { await client.operations().contains("activate:B") }

        let operations = await client.operations()
        let stopIndex = operations.firstIndex(of: "stop:A")
        let activationIndex = operations.firstIndex(of: "activate:B")
        #expect(stopIndex != nil)
        #expect(activationIndex != nil)
        if let stopIndex, let activationIndex { #expect(stopIndex < activationIndex) }
        await coordinator.close()
    }

    @Test("Close and shutdown restore a route before ending their device lifecycle")
    func closeAndShutdownStopRouteFirst() async {
        let closeClient = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let closeCoordinator = SimulatorPaneCoordinator(client: closeClient)
        await closeCoordinator.start()
        await eventually { await closeClient.operations().contains("activate:A") }
        await closeCoordinator.startLocationRoute(Self.route())

        await closeCoordinator.close()

        let closeOperations = await closeClient.operations()
        let closeStopIndex = closeOperations.firstIndex(of: "stop:A")
        let closeIndex = closeOperations.firstIndex(of: "close")
        #expect(closeStopIndex != nil)
        #expect(closeIndex != nil)
        if let closeStopIndex, let closeIndex { #expect(closeStopIndex < closeIndex) }

        let shutdownClient = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let shutdownCoordinator = SimulatorPaneCoordinator(client: shutdownClient)
        await shutdownCoordinator.start()
        await eventually { await shutdownClient.operations().contains("activate:A") }
        await shutdownCoordinator.startLocationRoute(Self.route())

        shutdownCoordinator.shutdownSelectedDevice()
        await eventually { await shutdownClient.operations().contains("shutdown:A") }

        let shutdownOperations = await shutdownClient.operations()
        let shutdownStopIndex = shutdownOperations.firstIndex(of: "stop:A")
        let shutdownIndex = shutdownOperations.firstIndex(of: "shutdown:A")
        #expect(shutdownStopIndex != nil)
        #expect(shutdownIndex != nil)
        if let shutdownStopIndex, let shutdownIndex { #expect(shutdownStopIndex < shutdownIndex) }
        await shutdownCoordinator.close()
    }

    @Test("Device loss and worker crash restore the active route")
    func lossAndCrashStopRoute() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.startLocationRoute(Self.route())

        await client.emit(.message(.status(.deviceUnavailable)))
        await eventually { await client.operations().filter { $0 == "stop:A" }.count == 1 }
        #expect(!coordinator.locationRouteIsActive)

        await coordinator.startLocationRoute(Self.route())
        await client.emit(.workerStopped)
        await eventually { await client.operations().filter { $0 == "stop:A" }.count == 2 }
        #expect(!coordinator.locationRouteIsActive)
        await coordinator.close()
    }

    @Test("Discovery restores a removed device route before selecting its fallback")
    func discoveryLossStopsRoute() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A"), Self.device("B")])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.startLocationRoute(Self.route())
        await client.setDevices([Self.device("B")])

        await coordinator.reloadDevices()

        #expect(coordinator.selectedDeviceID == "B")
        #expect(await client.operations().contains("stop:A"))
        #expect(!coordinator.locationRouteIsActive)
        await coordinator.close()
    }

    @Test("A non-loop route completes inactive and can replay")
    func naturalCompletionAndReplay() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let sleeper = LocationLifecyclePaneSleeper()
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            webInspectorSleeper: ImmediateLocationLifecyclePaneSleeper(),
            locationRouteSleeper: sleeper
        )
        await coordinator.start()

        await coordinator.startLocationRoute(Self.route())
        await sleeper.waitForStartCount(1)
        #expect(coordinator.locationRouteIsActive)

        await sleeper.advance()
        await eventually { !coordinator.locationRouteIsActive }
        #expect(!coordinator.locationRouteIsPaused)

        await coordinator.startLocationRoute(Self.route())
        await sleeper.waitForStartCount(2)
        #expect(coordinator.locationRouteIsActive)
        #expect(await client.operations().filter { $0 == "start:A" }.count == 2)

        await coordinator.close()
        await sleeper.waitForCancellationCount(1)
        #expect(await client.operations().contains("stop:A"))
    }

    private static func route() -> SimulatorLocationRoute {
        SimulatorLocationRoute(
            waypoints: [
                SimulatorLocationCoordinate(latitude: 37.7, longitude: -122.4),
                SimulatorLocationCoordinate(latitude: 37.71, longitude: -122.39),
            ],
            speed: 3
        )
    }

    private static func device(_ id: String) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: id,
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        for _ in 0..<300 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}

private actor LocationLifecyclePaneClient: SimulatorPaneClient {
    nonisolated let contextCache = SimulatorRemoteContextCache()
    private var deviceValues: [SimulatorDevice]
    private let stream: SimulatorWorkerEventStream
    private let continuation: SimulatorWorkerEventStream.Continuation
    private var operationValues: [String] = []

    init(devices: [SimulatorDevice]) {
        deviceValues = devices
        let (stream, continuation) = SimulatorWorkerEventStream.makeStream(
            maximumBufferedBytes: 4_096,
            maximumBufferedEvents: 32,
            onTermination: {}
        )
        self.stream = stream
        self.continuation = continuation
    }

    func discoverDevices() async throws -> [SimulatorDevice] { deviceValues }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        operationValues.append("activate:\(id)")
    }

    func shutdownDevice(id: String) async throws {
        operationValues.append("shutdown:\(id)")
    }

    func subscribe() async -> SimulatorWorkerEventStream { stream }
    func send(_ message: SimulatorWorkerInbound) async {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        switch action {
        case let .startLocationRoute(deviceID, _):
            operationValues.append("start:\(deviceID)")
        case let .stopLocationRoute(deviceID):
            operationValues.append("stop:\(deviceID)")
        default:
            break
        }
        return .none
    }

    func invalidateWorker() async {}

    func stop() async {
        operationValues.append("close")
        continuation.finish()
    }

    func emit(_ event: SimulatorWorkerEvent) {
        _ = continuation.yield(event)
    }

    func setDevices(_ devices: [SimulatorDevice]) { deviceValues = devices }
    func operations() -> [String] { operationValues }
}

private actor LocationLifecyclePaneSleeper: SimulatorProcessSleeper {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var startCount = 0
    private var cancellationCount = 0
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        _ = duration
        let id = UUID()
        startCount += 1
        resumeObservers(&startObservers, count: startCount)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func waitForStartCount(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { startObservers.append((count, $0)) }
    }

    func waitForCancellationCount(_ count: Int) async {
        guard cancellationCount < count else { return }
        await withCheckedContinuation { cancellationObservers.append((count, $0)) }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        cancellationCount += 1
        resumeObservers(&cancellationObservers, count: cancellationCount)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeObservers(
        _ observers: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let ready = observers.filter { $0.0 <= count }
        observers.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }
}

private struct ImmediateLocationLifecyclePaneSleeper: SimulatorProcessSleeper {
    func sleep(for duration: Duration) async throws {}
}
