import CmuxSimulator
@testable import CmuxSimulatorUI

actor StaleDiscoveryPaneClient: SimulatorPaneClient {
    private let eventStream: SimulatorWorkerEventStream
    private let eventContinuation: SimulatorWorkerEventStream.Continuation
    private var discoveryContinuation: CheckedContinuation<[SimulatorDevice], Never>?
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: 1_024,
            maximumBufferedEvents: 8,
            onTermination: {}
        )
        eventStream = source.stream
        eventContinuation = source.continuation
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        let waiters = discoveryWaiters
        discoveryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { discoveryContinuation = $0 }
    }

    func waitUntilDiscoveryIsPending() async {
        if discoveryContinuation != nil { return }
        await withCheckedContinuation { discoveryWaiters.append($0) }
    }

    func resumeDiscovery(with devices: [SimulatorDevice]) {
        discoveryContinuation?.resume(returning: devices)
        discoveryContinuation = nil
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
}
