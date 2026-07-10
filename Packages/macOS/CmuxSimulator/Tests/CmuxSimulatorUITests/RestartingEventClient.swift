import CmuxSimulator
@testable import CmuxSimulatorUI

actor RestartingEventClient: SimulatorPaneClient {
    nonisolated let contextCache = SimulatorRemoteContextCache()
    private var continuations: [SimulatorWorkerEventStream.Continuation] = []

    func discoverDevices() async throws -> [SimulatorDevice] {
        [SimulatorDevice(
            id: "DEVICE",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS",
            deviceTypeIdentifier: "phone",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )]
    }
    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {}
    func shutdownDevice(id: String) async throws {}

    func subscribe() async -> SimulatorWorkerEventStream {
        let (stream, continuation) = SimulatorWorkerEventStream.makeStream(
            maximumBufferedBytes: 1_024 * 1_024,
            maximumBufferedEvents: 64,
            onTermination: {}
        )
        continuations.append(continuation)
        return stream
    }

    func send(_ message: SimulatorWorkerInbound) async {}
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult { .none }
    func invalidateWorker() async {}
    func stop() async {}

    func subscriptionCount() -> Int { continuations.count }

    func finishSubscription(at index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func emit(_ event: SimulatorWorkerEvent, to index: Int) {
        guard continuations.indices.contains(index) else { return }
        _ = continuations[index].yield(event)
    }
}
