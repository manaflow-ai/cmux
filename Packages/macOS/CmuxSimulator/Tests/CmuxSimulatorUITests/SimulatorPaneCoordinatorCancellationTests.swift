import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane startup cancellation")
@MainActor
struct SimulatorPaneCoordinatorCancellationTests {
    @Test("Canceled discovery leaves no failure and a later start retries")
    func canceledDiscoveryCanRetry() async {
        let device = SimulatorDevice(
            id: "phone",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone-type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = CancellableDiscoveryPaneClient(device: device)
        let coordinator = SimulatorPaneCoordinator(client: client)
        let firstStart = Task { @MainActor in
            await coordinator.start()
        }

        await client.waitForFirstDiscovery()
        firstStart.cancel()
        await firstStart.value

        #expect(coordinator.failure == nil)
        #expect(coordinator.status == .idle)
        #expect(!coordinator.started)

        await coordinator.start()

        #expect(await client.discoveryCount() == 2)
        #expect(coordinator.devices.map(\.id) == ["phone"])
        #expect(coordinator.selectedDeviceID == "phone")
        await coordinator.close()
    }
}

private actor CancellableDiscoveryPaneClient: SimulatorPaneClient {
    nonisolated let contextCache = SimulatorRemoteContextCache()
    private let device: SimulatorDevice
    private let cancellationGate = TestCancellationGate()
    private let eventStream: SimulatorWorkerEventStream
    private let eventContinuation: SimulatorWorkerEventStream.Continuation
    private var discoveries = 0
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(device: SimulatorDevice) {
        self.device = device
        let (stream, continuation) = SimulatorWorkerEventStream.makeStream(
            maximumBufferedBytes: 1_024,
            maximumBufferedEvents: 8,
            onTermination: {}
        )
        eventStream = stream
        eventContinuation = continuation
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        discoveries += 1
        let waiters = discoveryWaiters
        discoveryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if discoveries == 1 {
            try await cancellationGate.waitUntilCancelled()
        }
        return [device]
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {}
    func shutdownDevice(id: String) async throws {}
    func subscribe() async -> SimulatorWorkerEventStream { eventStream }
    func send(_ message: SimulatorWorkerInbound) async {}
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult { .none }
    func invalidateWorker() async {}
    func stop() async { eventContinuation.finish() }

    func waitForFirstDiscovery() async {
        guard discoveries == 0 else { return }
        await withCheckedContinuation { discoveryWaiters.append($0) }
    }

    func discoveryCount() -> Int { discoveries }
}

private final class TestCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var isCancelled = false

    func waitUntilCancelled() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumesImmediately = lock.withLock {
                    if isCancelled { return true }
                    self.continuation = continuation
                    return false
                }
                if resumesImmediately { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                self.isCancelled = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
