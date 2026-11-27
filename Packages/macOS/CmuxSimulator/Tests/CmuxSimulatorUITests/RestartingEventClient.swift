import CmuxSimulator
@testable import CmuxSimulatorUI

actor RestartingEventClient: SimulatorPaneClient {
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
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: 1_024 * 1_024,
            maximumBufferedEvents: 64,
            onTermination: {}
        )
        continuations.append(source.continuation)
        return source.stream
    }

    func send(_ message: SimulatorWorkerInbound) async {}
    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? { nil }
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult { .none }
    func invalidateWorker() async {}
    func stop() async {}

    func subscriptionCount() -> Int { continuations.count }

    func finishSubscription(at index: Int) async {
        guard continuations.indices.contains(index) else { return }
        await continuations[index].finish()
    }

    func emit(_ event: SimulatorWorkerEvent, to index: Int) async {
        guard continuations.indices.contains(index) else { return }
        _ = await continuations[index].yield(event)
    }
}
