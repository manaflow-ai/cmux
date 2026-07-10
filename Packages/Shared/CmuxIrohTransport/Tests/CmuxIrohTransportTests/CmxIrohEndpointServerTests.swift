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
        let server = CmxIrohEndpointServer(supervisor: supervisor) { connection, generation in
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
        #expect(await server.isCurrent(runtimeGeneration: snapshot.runtimeGeneration))
        await server.stop()
        await supervisor.deactivate()
    }
}

private actor EndpointServerRecorder {
    typealias Event = (identity: CmxIrohPeerIdentity, generation: UInt64)
    private var events: [Event] = []
    private var waiters: [CheckedContinuation<Event, Never>] = []

    func record(identity: CmxIrohPeerIdentity, generation: UInt64) {
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
}

private actor TestAcceptingIrohEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity
    private var connections: [any CmxIrohConnection] = []
    private var waiters: [
        UUID: CheckedContinuation<(any CmxIrohConnection)?, Never>
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
        if !connections.isEmpty { return connections.removeFirst() }
        guard !closed else { return nil }
        let id = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelAccept(id) }
        }
        try Task.checkCancellation()
        return result
    }

    func replaceRelays(_: [CmxIrohRelayConfiguration]) {}
    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> { health }

    func close() {
        closed = true
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: nil) }
        healthContinuation.finish()
    }

    func enqueue(_ connection: any CmxIrohConnection) {
        if let id = waiters.keys.first, let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(returning: connection)
        } else {
            connections.append(connection)
        }
    }

    private func cancelAccept(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}
