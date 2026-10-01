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
    private enum ReplacementOutcome: Sendable {
        case predecessorClosed(code: UInt64, reason: String)
        case redialClosed(code: UInt64, reason: String)
    }

    /// Waits for the one deterministic signal that distinguishes the fixed
    /// behavior (the dead predecessor is superseded) from the defect (the
    /// redial itself is refused and closed).
    private static func firstReplacementOutcome(
        predecessor: TestIrohConnection,
        redial: TestIrohConnection
    ) async -> ReplacementOutcome {
        await withTaskGroup(of: ReplacementOutcome.self) { group in
            group.addTask {
                var closes = await predecessor.closeEvents().makeAsyncIterator()
                let close = await closes.next()
                return .predecessorClosed(
                    code: close?.code ?? 0,
                    reason: close?.reason ?? "stream_ended"
                )
            }
            group.addTask {
                var closes = await redial.closeEvents().makeAsyncIterator()
                let close = await closes.next()
                return .redialClosed(
                    code: close?.code ?? 0,
                    reason: close?.reason ?? "stream_ended"
                )
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? .redialClosed(code: 0, reason: "no_outcome")
        }
    }

    private static func waitForRecordedCount(
        _ recorder: EndpointServerRecorder,
        _ expected: Int
    ) async -> Bool {
        // Admission recording runs in a separate handler task from the close
        // watcher. Retry finite clock-bounded windows so a loaded runner can
        // absorb a scheduling stall without turning a real leak into a hang.
        for _ in 0 ..< 4 {
            let deadline = ContinuousClock().now.advanced(by: .seconds(1))
            while ContinuousClock().now < deadline {
                if await recorder.recordedCount() >= expected { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        return await recorder.recordedCount() >= expected
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
        switch outcome {
        case let .predecessorClosed(_, reason):
            #expect(reason == "superseded_connection")
            replacementAdmitted = true
        case let .redialClosed(_, reason):
            Issue.record(
                "same-identity redial was refused (\(reason)) instead of replacing its dead predecessor"
            )
            replacementAdmitted = false
        }
        // The close signal is delivered while the replacement handler is
        // still between promotion and its recording step, so wait for the
        // second admission event instead of sampling the actor immediately.
        let recordedReplacement: Bool
        if replacementAdmitted {
            recordedReplacement = await Self.waitForRecordedCount(recorder, 2)
        } else {
            recordedReplacement = false
        }
        #expect(recordedReplacement)
        if recordedReplacement {
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
        switch outcome {
        case let .predecessorClosed(_, reason):
            #expect(reason == "superseded_connection")
            replacementAdmitted = true
        case let .redialClosed(_, reason):
            Issue.record(
                "same-identity redial was refused (\(reason)) while its own dead predecessor held the global slot"
            )
            replacementAdmitted = false
        }
        let recordedReplacement: Bool
        if replacementAdmitted {
            recordedReplacement = await Self.waitForRecordedCount(recorder, 3)
        } else {
            recordedReplacement = false
        }
        #expect(recordedReplacement)
        if recordedReplacement {
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

        // The close event is delivered before the server actor necessarily
        // runs its watcher. Allow a bounded transient rejection while that
        // release is being scheduled, then retry with a fresh connection. A
        // daemon that never releases the slot exhausts this bounded loop.
        var admittedNewcomer: TestIrohConnection?
        for _ in 0 ..< 8 {
            let newcomer = TestIrohConnection(
                remoteIdentity: newcomerIdentity,
                bidirectionalStreams: []
            )
            await endpoint.enqueue(newcomer)
            let deadline = ContinuousClock().now.advanced(by: .seconds(1))
            while ContinuousClock().now < deadline {
                let admittedCount = await recorder.recordedCount()
                let newcomerCloseCount = await newcomer.observedCloseCallCount()
                if admittedCount == 2 || newcomerCloseCount > 0 { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            if await recorder.recordedCount() == 2 {
                admittedNewcomer = newcomer
                break
            }
            #expect(
                await newcomer.observedCloseCallCount() > 0,
                "newcomer neither admitted nor rejected within the bounded wait"
            )
        }
        #expect(await recorder.recordedCount() == 2)
        if let admittedNewcomer {
            #expect(await admittedNewcomer.observedCloseCallCount() == 0)
            #expect(await recorder.next().identity == newcomerIdentity)
        }

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }
}
