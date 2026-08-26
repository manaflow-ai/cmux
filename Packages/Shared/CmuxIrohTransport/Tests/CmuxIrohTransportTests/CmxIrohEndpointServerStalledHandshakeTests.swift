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

    /// A timed-out handshake cannot be aborted once the native attempt is
    /// consumed (task cancellation does not reach the driver), so its
    /// admission slot must stay occupied until the attempt itself resolves.
    /// Releasing the slot at the admission deadline lets a remote peer mint
    /// more live handshake work than `maximumPendingAdmissions` permits.
    @Test
    func timedOutHandshakeKeepsItsSlotUntilTheAttemptResolves() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "e", count: 64)
        )
        let healthyIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "f", count: 64)
        )
        let endpoint = StalledHandshakeIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 10, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: []
            )
        )
        _ = try await supervisor.activate()
        let clock = EndpointServerManualClock()
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
            await connection.close(errorCode: 0, reason: "test_complete")
        }

        await server.start()
        await endpoint.enqueueStalledHandshake()
        await clock.waitUntilSleeping()
        await clock.fire()
        // The admission deadline fired against a handshake that never
        // resolves on cancellation. The dialer is refused fast...
        await endpoint.waitForAbandonCount(1)

        // ...but the slot must still be occupied: the next attempt has to be
        // abandoned by the accept loop, not admitted alongside the live
        // stalled handshake. Deterministic either way: the fix abandons the
        // attempt ("admission_abandoned"), the defect admits it and the
        // handler closes it "test_complete".
        let overCapacity = TestIrohConnection(
            remoteIdentity: healthyIdentity,
            bidirectionalStreams: []
        )
        var overCapacityCloses = await overCapacity.closeEvents().makeAsyncIterator()
        await endpoint.enqueue(overCapacity)
        let close = try #require(await overCapacityCloses.next())
        #expect(close.reason == "admission_abandoned")

        // The driver finally bounds the stalled attempt. Its resolution, not
        // the earlier deadline, releases the slot.
        await endpoint.releaseStalledHandshakes()
        let admittedAfterResolution = TestIrohConnection(
            remoteIdentity: healthyIdentity,
            bidirectionalStreams: []
        )
        await endpoint.enqueue(admittedAfterResolution)
        #expect(await recorder.next().identity == healthyIdentity)

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
    private var abandonCount = 0
    private var abandonWaiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
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

    func accept() async throws -> (any CmxIrohIncomingConnection)? {
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
            return StalledIncomingConnection(endpoint: self)
        case let .connection(connection):
            return CmxIrohEstablishedIncomingConnection(connection)
        }
    }

    func awaitStallRelease() async {
        await withCheckedContinuation { stallWaiters.append($0) }
    }

    func recordAbandon() {
        abandonCount += 1
        let ready = abandonWaiters.filter { abandonCount >= $0.minimum }
        abandonWaiters.removeAll { abandonCount >= $0.minimum }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForAbandonCount(_ minimum: Int) async {
        guard abandonCount < minimum else { return }
        await withCheckedContinuation {
            abandonWaiters.append((minimum, $0))
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

/// An incoming attempt whose server-side handshake makes no progress until the
/// endpoint releases it, then fails like an aborted handshake.
private struct StalledIncomingConnection: CmxIrohIncomingConnection {
    let endpoint: StalledHandshakeIrohEndpoint

    func establish() async throws -> any CmxIrohConnection {
        await endpoint.awaitStallRelease()
        throw TestIrohTransportError.unsupported
    }

    func abandon() async {
        // Refusing a consumed attempt cannot stop the in-flight handshake,
        // exactly like `Incoming.refuse()` after `accept()`.
        await endpoint.recordAbandon()
    }
}
