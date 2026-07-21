import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohEndpointServerTests {
    @Test
    func activeGenerationAcceptsThroughTheBoundedServerLoop() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 1, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        let snapshot = try await supervisor.activate()
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        await endpoint.enqueue(connection)
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(supervisor: supervisor) { connection, generation, _ in
            let identity = await connection.remoteIdentity()
            await recorder.record(
                identity: identity,
                generation: generation
            )
            await connection.close(errorCode: 0, reason: "test_complete")
        }

        await server.start()
        let observed = await recorder.next()

        #expect(observed.identity == remoteIdentity)
        #expect(observed.generation == snapshot.runtimeGeneration)
        #expect(
            await server.isCurrent(runtimeGeneration: snapshot.runtimeGeneration)
        )
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func oneFailedAcceptDoesNotKillTheActiveGeneration() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "1", count: 64)
        )
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "2", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 4, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        let snapshot = try await supervisor.activate()
        let clock = EndpointServerManualClock()
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            clock: clock
        ) { connection, generation, _ in
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
        }

        await server.start()
        await endpoint.enqueueAcceptFailure()
        await clock.waitUntilSleeping()
        await clock.fire()
        await endpoint.enqueue(
            TestIrohConnection(
                remoteIdentity: remoteIdentity,
                bidirectionalStreams: []
            )
        )

        let observed = await recorder.next()
        #expect(observed.identity == remoteIdentity)
        #expect(observed.generation == snapshot.runtimeGeneration)
        #expect(await server.isCurrent(runtimeGeneration: snapshot.runtimeGeneration))
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func admissionTimeoutClosesTheConnectionAndReleasesCapacity() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "c", count: 64)
        )
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "d", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 2, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        _ = try await supervisor.activate()
        let clock = EndpointServerManualClock()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumPendingAdmissions: 1,
            admissionTimeout: 15,
            clock: clock
        ) { connection, generation, _ in
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            await blocker.wait()
        }
        let first = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        var firstCloses = await first.closeEvents().makeAsyncIterator()

        await server.start()
        await endpoint.enqueue(first)
        _ = await recorder.next()
        await clock.waitUntilSleeping()
        await clock.fire()

        let close = try #require(await firstCloses.next())
        #expect(close.reason == "admission_timeout")

        let second = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        await endpoint.enqueue(second)
        let admittedAfterTimeout = await recorder.next()
        #expect(admittedAfterTimeout.identity == remoteIdentity)

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func admittedHandlerOutlivesPendingAdmissionDeadline() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "8", count: 64)
        )
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "9", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 8, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        _ = try await supervisor.activate()
        let clock = EndpointServerManualClock()
        let admissionGate = EndpointServerHandlerBlocker()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        let admitted = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            admissionTimeout: 15,
            clock: clock
        ) { connection, generation, markAdmitted in
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            await admissionGate.wait()
            #expect(await markAdmitted())
            await admitted.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            await blocker.wait()
        }
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        var closes = await connection.closeEvents().makeAsyncIterator()

        await server.start()
        await endpoint.enqueue(connection)
        #expect(await recorder.next().identity == remoteIdentity)
        await clock.waitUntilSleeping()
        await admissionGate.releaseAll()
        #expect(await admitted.next().identity == remoteIdentity)
        await clock.fire()

        #expect(await connection.observedCloseCallCount() == 0)
        await server.stop()
        let close = try #require(await closes.next())
        #expect(close.reason == "server_stopped")

        await blocker.releaseAll()
        await supervisor.deactivate()
    }

    @Test
    func newlyAdmittedConnectionSupersedesOlderConnectionFromSameEndpointIdentity() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 9, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        _ = try await supervisor.activate()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(supervisor: supervisor) {
            connection,
            generation,
            markAdmitted in
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            #expect(await markAdmitted())
            await blocker.wait()
        }
        let first = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        let replacement = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        var firstCloses = await first.closeEvents().makeAsyncIterator()

        await server.start()
        await endpoint.enqueue(first)
        #expect(await recorder.next().identity == remoteIdentity)
        await endpoint.enqueue(replacement)
        #expect(await recorder.next().identity == remoteIdentity)

        for _ in 0 ..< 20 { await Task.yield() }
        let firstCloseCount = await first.observedCloseCallCount()
        #expect(firstCloseCount == 1)
        if firstCloseCount == 1 {
            let close = try #require(await firstCloses.next())
            #expect(close.reason == "superseded_connection")
        }
        #expect(await replacement.observedCloseCallCount() == 0)

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }

}

actor EndpointServerHandlerBlocker {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

actor EndpointServerManualClock: CmxIrohRelayClock {
    private var sleeper: CheckedContinuation<Void, Never>?
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func now() -> Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    func sleep(until _: Date) async throws {
        let waiters = sleepWaiters
        sleepWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleeper = $0 }
        } onCancel: {
            Task { await self.cancelSleep() }
        }
        try Task.checkCancellation()
    }

    func waitUntilSleeping() async {
        if sleeper != nil { return }
        await withCheckedContinuation { sleepWaiters.append($0) }
    }

    func fire() {
        sleeper?.resume()
        sleeper = nil
    }

    private func cancelSleep() {
        sleeper?.resume()
        sleeper = nil
    }
}

actor EndpointServerRecorder {
    typealias Event = (identity: CmxIrohPeerIdentity, generation: UInt64)
    private var events: [Event] = []
    private var waiters: [CheckedContinuation<Event, Never>] = []
    private var totalRecordedCount = 0

    func record(identity: CmxIrohPeerIdentity, generation: UInt64) {
        totalRecordedCount += 1
        let event = (identity, generation)
        if waiters.isEmpty {
            events.append(event)
        } else {
            waiters.removeFirst().resume(returning: event)
        }
    }

    func next() async -> Event {
        if !events.isEmpty { return events.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func recordedCount() -> Int {
        totalRecordedCount
    }
}

actor TestAcceptingIrohEndpoint: CmxIrohEndpoint {
    private enum AcceptEvent: Sendable {
        case connection(any CmxIrohConnection)
        case failure
        case closed
    }

    private let peerIdentity: CmxIrohPeerIdentity
    private var acceptEvents: [AcceptEvent] = []
    private var waiters: [
        UUID: CheckedContinuation<AcceptEvent, Never>
    ] = [:]
    private let health: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    private var closed = false

    init(identity: CmxIrohPeerIdentity) {
        peerIdentity = identity
        let stream = AsyncStream<CmxIrohEndpointHealthEvent>.makeStream()
        health = stream.stream
        healthContinuation = stream.continuation
    }

    func identity() -> CmxIrohPeerIdentity { peerIdentity }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: peerIdentity, pathHints: [])
    }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) async throws -> any CmxIrohConnection {
        throw TestIrohTransportError.unsupported
    }

    func accept() async throws -> (any CmxIrohConnection)? {
        try Task.checkCancellation()
        if !acceptEvents.isEmpty {
            return try Self.resolve(acceptEvents.removeFirst())
        }
        guard !closed else { return nil }
        let id = UUID()
        let event = await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelAccept(id) }
        }
        try Task.checkCancellation()
        return try Self.resolve(event)
    }

    func replaceRelays(_: [CmxIrohRelayConfiguration]) {}
    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> { health }
    func isHealthy() -> Bool { true }

    func close() {
        closed = true
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: .closed) }
        healthContinuation.finish()
    }

    func enqueue(_ connection: any CmxIrohConnection) {
        enqueue(.connection(connection))
    }

    func enqueueAcceptFailure() {
        enqueue(.failure)
    }

    private func enqueue(_ event: AcceptEvent) {
        if let id = waiters.keys.first, let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(returning: event)
        } else {
            acceptEvents.append(event)
        }
    }

    private func cancelAccept(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .closed)
    }

    nonisolated private static func resolve(
        _ event: AcceptEvent
    ) throws -> (any CmxIrohConnection)? {
        switch event {
        case let .connection(connection): connection
        case .failure: throw TestIrohTransportError.unsupported
        case .closed: nil
        }
    }
}
