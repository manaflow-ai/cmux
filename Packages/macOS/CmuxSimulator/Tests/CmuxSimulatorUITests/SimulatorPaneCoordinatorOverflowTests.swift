import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane bounded output")
struct SimulatorPaneCoordinatorOverflowTests {
    @Test("Outgoing overflow releases held input and stops the worker")
    @MainActor
    func outgoingOverflow() async {
        let device = Self.device()
        let client = SimulatorPaneClientSpy(devices: [device])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()
        let keyDown = SimulatorWorkerInbound.key(SimulatorKeyEvent(usage: 4, phase: .down))
        for _ in 0..<SimulatorPaneCoordinator.maximumOutgoingMessageCount {
            coordinator.enqueue(keyDown)
        }
        coordinator.enqueue(.key(SimulatorKeyEvent(usage: 4, phase: .up)))

        for _ in 0..<1_000 {
            if await client.invalidationCount() > 0 { break }
            await Task.yield()
        }

        #expect(coordinator.failure?.code == "simulator_outgoing_queue_overflow")
        #expect(coordinator.status == .workerCrashed)
        #expect(await client.messages().contains(.releaseInputs))
        #expect(await client.invalidationCount() == 1)
        #expect(await client.stopCount() == 0)

        coordinator.recover()
        for _ in 0..<1_000 {
            if await client.activations().count == 1 { break }
            await Task.yield()
        }
        coordinator.enqueue(keyDown)
        let keyUp = SimulatorWorkerInbound.key(SimulatorKeyEvent(usage: 4, phase: .up))
        coordinator.enqueue(keyUp)
        for _ in 0..<1_000 {
            if Array((await client.messages()).suffix(2)) == [keyDown, keyUp] { break }
            await Task.yield()
        }

        #expect(await client.activations().count == 1)
        #expect(Array((await client.messages()).suffix(2)) == [keyDown, keyUp])
        await coordinator.close()
    }

    @Test("Event observation resubscribes once after worker restart")
    @MainActor
    func resubscribesAfterEventOverflow() async {
        let client = RestartingEventClient()
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        for _ in 0..<1_000 {
            if await client.subscriptionCount() == 1 { break }
            await Task.yield()
        }
        await client.finishSubscription(at: 0)
        for _ in 0..<1_000 {
            if await client.subscriptionCount() == 2 { break }
            await Task.yield()
        }
        await client.emit(.message(.status(.streaming)), to: 1)
        for _ in 0..<1_000 {
            if coordinator.status == .streaming { break }
            await Task.yield()
        }

        #expect(await client.subscriptionCount() == 2)
        #expect(coordinator.status == .streaming)

        await client.finishSubscription(at: 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(await client.subscriptionCount() == 2)

        coordinator.recover()
        for _ in 0..<1_000 {
            if await client.subscriptionCount() == 3 { break }
            await Task.yield()
        }
        await client.emit(.message(.status(.streaming)), to: 2)
        for _ in 0..<1_000 {
            if coordinator.status == .streaming { break }
            await Task.yield()
        }

        #expect(await client.subscriptionCount() == 3)
        #expect(coordinator.status == .streaming)
        await coordinator.close()
    }

    private static func device() -> SimulatorDevice {
        SimulatorDevice(
            id: "DEVICE",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS",
            deviceTypeIdentifier: "phone",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
    }
}

private actor RestartingEventClient: SimulatorPaneClient {
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
