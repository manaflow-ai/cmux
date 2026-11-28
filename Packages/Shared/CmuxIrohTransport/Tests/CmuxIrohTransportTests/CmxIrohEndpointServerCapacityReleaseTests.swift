import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Admission capacity must be tied to connection liveness, not to the idle
/// timer alone. A client that dies abnormally (no clean close) leaves a dead
/// connection whose handler never returns; the same TLS-authenticated identity
/// must still be admitted promptly on redial, and a transport-reported close
/// must release the slot without waiting for the handler to unwind. Strangers
/// can never preempt another identity's capacity.
@Suite
struct CmxIrohEndpointServerCapacityReleaseTests {
    /// Waits for the one deterministic signal that distinguishes the fixed
    /// behavior (the dead predecessor is superseded) from the defect (the
    /// redial itself is refused and closed).
    private static func firstReplacementOutcome(
        predecessor: TestIrohConnection,
        redial: TestIrohConnection
    ) async -> (predecessorClosed: Bool, reason: String) {
        await withTaskGroup(of: (predecessorClosed: Bool, reason: String).self) { group in
            group.addTask {
                var closes = await predecessor.closeEvents().makeAsyncIterator()
                let close = await closes.next()
                return (true, close?.reason ?? "stream_ended")
            }
            group.addTask {
                var closes = await redial.closeEvents().makeAsyncIterator()
                let close = await closes.next()
                return (false, close?.reason ?? "stream_ended")
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? (false, "no_outcome")
        }
    }

    private static func makeSupervisor(
        endpoint: TestAcceptingIrohEndpoint,
        keyByte: UInt8
    ) throws -> CmxIrohEndpointSupervisor {
        CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: keyByte, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
    }

    @Test
    func sameIdentityRedialAfterAbnormalPeerDeathIsAdmittedPromptly() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "1", count: 64)
        )
        let clientIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "2", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = try Self.makeSupervisor(endpoint: endpoint, keyByte: 11)
        _ = try await supervisor.activate()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        // The identity is at its full capacity with one usable session, the
        // worst case an abnormal client death leaves behind.
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumConnections: 1,
            maximumConnectionsPerIdentity: 1
        ) { connection, generation, admission in
            #expect(await admission())
            #expect(await admission.markUsable())
            // Recording after promotion makes each recorded event mean "this
            // session is fully admitted AND usable", which removes ordering
            // races between a predecessor's promotion and the next dial.
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            // The dead peer never closes cleanly: its handler stays parked
            // exactly like a session read against a silently dead QUIC peer.
            await blocker.wait()
        }
        let deadPredecessor = TestIrohConnection(
            remoteIdentity: clientIdentity,
            bidirectionalStreams: []
        )
        let redial = TestIrohConnection(
            remoteIdentity: clientIdentity,
            bidirectionalStreams: []
        )

        await server.start()
        await endpoint.enqueue(deadPredecessor)
        #expect(await recorder.next().identity == clientIdentity)

        // The client process died abnormally; no close arrives. The SAME
        // identity redials and must be admitted before any idle timeout.
        await endpoint.enqueue(redial)
        let outcome = await Self.firstReplacementOutcome(
            predecessor: deadPredecessor,
            redial: redial
        )
        let replacementAdmitted: Bool
        if outcome.predecessorClosed {
            let reason = outcome.reason
            #expect(reason == "superseded_connection")
            replacementAdmitted = true
        } else {
            let reason = outcome.reason
            Issue.record(
                "same-identity redial was refused (\(reason)) instead of replacing its dead predecessor"
            )
            replacementAdmitted = false
        }
        // The close signal is delivered while the replacement handler is
        // still between promotion and its recording step, so wait for the
        // second admission event instead of sampling the actor immediately.
        if replacementAdmitted {
            #expect(await recorder.next().identity == clientIdentity)
        }
        #expect(await recorder.recordedCount() == 2)
        #expect(await redial.observedCloseCallCount() == 0)

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func deadPredecessorHoldingAGlobalSlotDoesNotRefuseItsOwnIdentitysRedial() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "3", count: 64)
        )
        let deadClientIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "4", count: 64)
        )
        let liveClientIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "5", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = try Self.makeSupervisor(endpoint: endpoint, keyByte: 12)
        _ = try await supervisor.activate()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        // The global pool is full: one dead session plus one live session
        // belonging to another identity.
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumConnections: 2,
            maximumConnectionsPerIdentity: 2
        ) { connection, generation, admission in
            #expect(await admission())
            #expect(await admission.markUsable())
            // Recording after promotion makes each recorded event mean "this
            // session is fully admitted AND usable", which removes ordering
            // races between a predecessor's promotion and the next dial.
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            await blocker.wait()
        }
        let deadPredecessor = TestIrohConnection(
            remoteIdentity: deadClientIdentity,
            bidirectionalStreams: []
        )
        let liveBystander = TestIrohConnection(
            remoteIdentity: liveClientIdentity,
            bidirectionalStreams: []
        )
        let redial = TestIrohConnection(
            remoteIdentity: deadClientIdentity,
            bidirectionalStreams: []
        )

        await server.start()
        await endpoint.enqueue(deadPredecessor)
        #expect(await recorder.next().identity == deadClientIdentity)
        await endpoint.enqueue(liveBystander)
        #expect(await recorder.next().identity == liveClientIdentity)

        await endpoint.enqueue(redial)
        let outcome = await Self.firstReplacementOutcome(
            predecessor: deadPredecessor,
            redial: redial
        )
        let replacementAdmitted: Bool
        if outcome.predecessorClosed {
            let reason = outcome.reason
            #expect(reason == "superseded_connection")
            replacementAdmitted = true
        } else {
            let reason = outcome.reason
            Issue.record(
                "same-identity redial was refused (\(reason)) while its own dead predecessor held the global slot"
            )
            replacementAdmitted = false
        }
        if replacementAdmitted {
            #expect(await recorder.next().identity == deadClientIdentity)
        }
        #expect(await recorder.recordedCount() == 3)
        #expect(await redial.observedCloseCallCount() == 0)
        // Replacing your own dead predecessor must never disturb another
        // identity's live session.
        #expect(await liveBystander.observedCloseCallCount() == 0)

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func differentIdentityCannotPreemptAnotherIdentitysSlot() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "6", count: 64)
        )
        let clientIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "7", count: 64)
        )
        let strangerIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "8", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = try Self.makeSupervisor(endpoint: endpoint, keyByte: 13)
        _ = try await supervisor.activate()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumConnections: 1,
            maximumConnectionsPerIdentity: 1
        ) { connection, generation, admission in
            #expect(await admission())
            #expect(await admission.markUsable())
            // Recording after promotion makes each recorded event mean "this
            // session is fully admitted AND usable", which removes ordering
            // races between a predecessor's promotion and the next dial.
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            await blocker.wait()
        }
        let occupant = TestIrohConnection(
            remoteIdentity: clientIdentity,
            bidirectionalStreams: []
        )
        let stranger = TestIrohConnection(
            remoteIdentity: strangerIdentity,
            bidirectionalStreams: []
        )
        var strangerCloses = await stranger.closeEvents().makeAsyncIterator()

        await server.start()
        await endpoint.enqueue(occupant)
        #expect(await recorder.next().identity == clientIdentity)

        // A different, fully authenticated identity dials into the full
        // server: it must be refused, and the occupant must keep its slot.
        await endpoint.enqueue(stranger)
        let close = try #require(await strangerCloses.next())
        #expect(close.reason == "connection_capacity")
        #expect(await occupant.observedCloseCallCount() == 0)
        #expect(await recorder.recordedCount() == 1)

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func transportReportedCloseReleasesTheSlotWithoutWaitingForTheHandler() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "9", count: 64)
        )
        let clientIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let newcomerIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = try Self.makeSupervisor(endpoint: endpoint, keyByte: 14)
        _ = try await supervisor.activate()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        let newcomerAdmissions = AsyncStream<CmxIrohPeerIdentity>.makeStream()
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumConnections: 1,
            maximumConnectionsPerIdentity: 1
        ) { connection, generation, admission in
            #expect(await admission())
            #expect(await admission.markUsable())
            // Recording after promotion makes each recorded event mean "this
            // session is fully admitted AND usable", which removes ordering
            // races between a predecessor's promotion and the next dial.
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            let identity = await connection.remoteIdentity()
            if identity == newcomerIdentity {
                newcomerAdmissions.continuation.yield(identity)
            }
            // The handler never unwinds on its own, like a serve loop that has
            // not yet observed the failed connection.
            await blocker.wait()
        }
        let occupant = TestIrohConnection(
            remoteIdentity: clientIdentity,
            bidirectionalStreams: []
        )
        await server.start()
        await endpoint.enqueue(occupant)
        #expect(await recorder.next().identity == clientIdentity)

        // The transport reports the connection terminal (reset, error, or its
        // own timeout). The slot must be released on that signal immediately,
        // not when the parked handler eventually returns.
        await occupant.close(errorCode: 0, reason: "transport_reported_loss")

        let newcomer = TestIrohConnection(
            remoteIdentity: newcomerIdentity,
            bidirectionalStreams: []
        )
        let newcomerCloseStream = await newcomer.closeEvents()
        await endpoint.enqueue(newcomer)

        let outcome = await withTaskGroup(
            of: (admitted: Bool, identity: CmxIrohPeerIdentity?, reason: String?).self
        ) { group in
            group.addTask {
                for await identity in newcomerAdmissions.stream {
                    return (true, identity, nil)
                }
                return (false, nil, "admission stream ended")
            }
            group.addTask {
                for await close in newcomerCloseStream {
                    return (false, nil, close.reason)
                }
                return (false, nil, "close stream ended")
            }
            let first = await group.next() ?? (false, nil, "no admission outcome")
            group.cancelAll()
            return first
        }
        if outcome.admitted {
            #expect(outcome.identity == newcomerIdentity)
            #expect(await newcomer.observedCloseCallCount() == 0)
            #expect(await recorder.recordedCount() == 2)
        } else {
            Issue.record(
                "newcomer was rejected after transport close: \(outcome.reason ?? "unknown")"
            )
        }

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }
}
