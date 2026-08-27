import CmuxSimulator
import Foundation
@testable import CmuxSimulatorUI

actor CancellableDiscoveryPaneClient: SimulatorPaneClient {
    private let device: SimulatorDevice
    private let cancellationGate = TestCancellationGate()
    private let eventStream: SimulatorWorkerEventStream
    private let eventContinuation: SimulatorWorkerEventStream.Continuation
    private var discoveries = 0
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(device: SimulatorDevice) {
        self.device = device
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: 1_024,
            maximumBufferedEvents: 8,
            onTermination: {}
        )
        eventStream = source.stream
        eventContinuation = source.continuation
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
    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? { nil }
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult { .none }
    func invalidateWorker() async {}
    func stop() async { await eventContinuation.finish() }

    func waitForFirstDiscovery() async {
        guard discoveries == 0 else { return }
        await withCheckedContinuation { discoveryWaiters.append($0) }
    }

    func discoveryCount() -> Int { discoveries }
}
