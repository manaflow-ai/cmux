import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Regression coverage for the Mac-host relay wedge: a peer that initiates a
/// connection and then stops making handshake progress (killed client, dead
/// relay path) must never gate other peers' admissions.
///
/// The 2026-08-26 itest timing batch showed the live failure shape: after one
/// abnormal client death, the host stayed broker-registered and relay-attached
/// (its relay TCP connection was unchanged on the relay's side), yet every new
/// dial timed out until the host app was restarted. The host's accept pipeline
/// performed the entire server-side handshake inline in the one serial accept
/// loop, so a single stalled handshake blocked every subsequent admission.
@Suite
struct CmxIrohEndpointServerStalledHandshakeTests {
    @Test
    func aPeerStalledMidHandshakeDoesNotBlockOtherAdmissions() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "c", count: 64)
        )
        let healthyIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "d", count: 64)
        )
        let endpoint = StalledHandshakeIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 9, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: []
            )
        )
        _ = try await supervisor.activate()
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(supervisor: supervisor) { connection, generation, _ in
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            await connection.close(errorCode: 0, reason: "test_complete")
        }

        await server.start()
        // One connection attempt whose server-side handshake never completes,
        // followed by a healthy peer waiting behind it.
        await endpoint.enqueueStalledHandshake()
        await endpoint.enqueue(
            TestIrohConnection(
                remoteIdentity: healthyIdentity,
                bidirectionalStreams: []
            )
        )

        var admittedCount = 0
        for _ in 0 ..< 200 {
            admittedCount = await recorder.recordedCount()
            if admittedCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(admittedCount == 1)
        if admittedCount == 1 {
            let admitted = await recorder.next()
            #expect(admitted.identity == healthyIdentity)
        }

        await endpoint.releaseStalledHandshakes()
        await server.stop()
        await supervisor.deactivate()
    }
}

/// An endpoint whose accept queue can contain a connection attempt that stops
/// making handshake progress, exactly like the production iroh accept path
/// when the dialing peer dies after its Initial packet.
private actor StalledHandshakeIrohEndpoint: CmxIrohEndpoint {
    private enum AcceptEvent: Sendable {
        case stalledHandshake
        case connection(any CmxIrohConnection)
    }

    private let peerIdentity: CmxIrohPeerIdentity
    private var acceptEvents: [AcceptEvent] = []
    private var acceptWaiters: [UUID: CheckedContinuation<AcceptEvent, Never>] = [:]
    private var stallWaiters: [CheckedContinuation<Void, Never>] = []
    private let health: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation

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
        let event: AcceptEvent
        if !acceptEvents.isEmpty {
            event = acceptEvents.removeFirst()
        } else {
            let id = UUID()
            event = await withCheckedContinuation { acceptWaiters[id] = $0 }
        }
        switch event {
        case .stalledHandshake:
            // The dialing peer sent its Initial packet and then died. The
            // server-side handshake never completes until release.
            await withCheckedContinuation { stallWaiters.append($0) }
            return nil
        case let .connection(connection):
            return connection
        }
    }

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> { health }
    func isHealthy() -> Bool { true }

    func close() {
        releaseStalledHandshakes()
        healthContinuation.finish()
    }

    func enqueue(_ connection: any CmxIrohConnection) {
        deliver(.connection(connection))
    }

    func enqueueStalledHandshake() {
        deliver(.stalledHandshake)
    }

    func releaseStalledHandshakes() {
        let waiters = stallWaiters
        stallWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func deliver(_ event: AcceptEvent) {
        if let id = acceptWaiters.keys.first,
           let continuation = acceptWaiters.removeValue(forKey: id) {
            continuation.resume(returning: event)
        } else {
            acceptEvents.append(event)
        }
    }
}
