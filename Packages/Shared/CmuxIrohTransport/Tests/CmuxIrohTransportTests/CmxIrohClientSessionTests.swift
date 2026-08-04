import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientSessionTests {
    let localIdentity: CmxIrohPeerIdentity
    let remoteIdentity: CmxIrohPeerIdentity
    let credential: CmxIrohAdmissionCredential

    init() throws {
        localIdentity = try CmxIrohPeerIdentity(endpointID: String(repeating: "ab", count: 32))
        remoteIdentity = try CmxIrohPeerIdentity(endpointID: String(repeating: "cd", count: 32))
        credential = try .pairGrant("e30.e30.AA")
    }

    @Test
    func publicDialAdmitsControlAndPreservesFollowingRPCBytes() async throws {
        let events = TestIrohEventRecorder()
        let control = controlStream(
            decision: .accepted,
            trailingBytes: Data("rpc".utf8),
            eventRecorder: events
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream],
            eventRecorder: events
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let publicHint = try publicRelayHint()
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(publicPaths: [publicHint]),
            credential: credential
        )

        try await session.connect()
        #expect(await session.connectionContinuityID() == 1)

        // Admission must not grant peer-initiated stream credit before a
        // production owner is installed. The dedicated server-events receiver
        // raises only the one unidirectional credit it owns.
        #expect(await connection.observedIncomingStreamLimits() == ["0:0"])
        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 1)
        #expect(await connection.observedNatTraversalActivationCount() == 1)
        #expect(await connection.observedBidirectionalStreamOpenCount() == 1)
        let dialed = await endpoint.observedDialedAddresses()
        #expect(dialed == [CmxIrohEndpointAddress(identity: remoteIdentity, pathHints: [publicHint])])
        let sent = await control.send.observedSentBuffers()
        let encodedHeader = try #require(sent.first)
        let clientReady = try #require(sent.dropFirst().first)
        #expect(sent.count == 2)
        let decodedHeader = try CmxIrohStreamHeaderCodec().decodePrefix(encodedHeader).header
        let expectedHeader = try CmxIrohStreamHeader(lane: .control, credential: credential)
        #expect(decodedHeader == expectedHeader)
        #expect(clientReady == admissionFrame(status: 2))
        #expect(await events.observedEvents() == [
            "connection.limits:0:0",
            "connection.openBidirectionalStream",
            "control.send",
            "connection.authorizeNatTraversal",
            "control.send",
        ])
        #expect(try await session.receiveControl() == Data("rpc".utf8))
    }

    @Test
    func closedNativeConnectionDoesNotReportContinuityIdentity() async throws {
        let control = controlStream(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            continuityID: 42,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )

        try await session.connect()
        #expect(await session.connectionContinuityID() == 42)

        await connection.close(errorCode: 0, reason: "expired")

        #expect(await session.connectionContinuityID() == nil)
    }

    @Test
    func repeatedConnectDoesNotRepeatNatTraversalAuthorization() async throws {
        let control = controlStream(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )

        try await session.connect()
        try await session.connect()

        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 1)
        #expect(await connection.observedNatTraversalActivationCount() == 1)
        #expect(await connection.observedBidirectionalStreamOpenCount() == 1)
        #expect(await endpoint.observedDialedAddresses().count == 1)
    }

    @Test
    func relayOnlyAdmissionCompletesBarrierWithoutAuthorizingNatTraversal() async throws {
        let events = TestIrohEventRecorder()
        let control = controlStream(
            decision: .accepted,
            acceptedFrame: .acceptedRelayOnly,
            trailingBytes: Data("rpc".utf8),
            eventRecorder: events
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream],
            eventRecorder: events
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )

        try await session.connect()

        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 0)
        #expect(await connection.observedNatTraversalActivationCount() == 0)
        #expect(await control.send.observedSentBuffers().count == 2)
        #expect(await events.observedEvents() == [
            "connection.limits:0:0",
            "connection.openBidirectionalStream",
            "control.send",
            "control.send",
        ])
        #expect(try await session.receiveControl() == Data("rpc".utf8))
    }

    @Test
    func privateHintsAreAttemptedOnlyAfterPublicFailure() async throws {
        let control = controlStream(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [
                .failure(.unsupported),
                .connection(connection),
            ]
        )
        let publicHint = try publicRelayHint()
        let privateHint = try tailscaleHint()
        let authorization = try privateFallbackAuthorization(for: [privateHint])
        let validator = TestPrivateFallbackValidator()
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(
                publicPaths: [publicHint],
                privateFallbackPaths: [privateHint]
            ),
            credential: credential,
            privateFallbackAuthorization: authorization,
            privateFallbackValidator: validator
        )

        try await session.connect()

        let dialed = await endpoint.observedDialedAddresses()
        #expect(dialed.map(\.pathHints) == [[publicHint], [privateHint]])
        #expect(await validator.observedAuthorizations() == [authorization])
    }

    @Test
    func emptyPublicPlanFailsTypedWithoutCallingTheNativeDialer() async throws {
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.failure(.unsupported)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(publicPaths: [], privateFallbackPaths: []),
            credential: credential
        )

        await #expect(throws: CmxIrohRegistryContextError.dialPlanUnavailable) {
            try await session.connect()
        }
        #expect(await endpoint.observedDialedAddresses().isEmpty)
    }

    @Test
    func emptyPublicPlanResolvesAndValidatesPrivateFallbackBeforeDialing() async throws {
        let control = controlStream(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let privateHint = try tailscaleHint()
        let authorization = try privateFallbackAuthorization(for: [privateHint])
        let validator = TestPrivateFallbackValidator()
        let fallbackContext = CmxIrohClientContext(
            dialPlan: try testIrohDialPlan(
                publicPaths: [],
                privateFallbackPaths: [privateHint]
            ),
            credential: credential,
            privateFallbackAuthorization: authorization
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(publicPaths: [], privateFallbackPaths: []),
            credential: credential,
            privateFallbackValidator: validator,
            privateFallbackContextProvider: { fallbackContext }
        )

        try await session.connect()

        #expect(await endpoint.observedDialedAddresses().map(\.pathHints) == [[privateHint]])
        #expect(await validator.observedAuthorizations() == [authorization])
    }

    @Test
    func privateFallbackIsNotDialedWhenItsNetworkStateCannotBeRevalidated() async throws {
        let control = controlStream(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [
                .failure(.unsupported),
                .connection(connection),
            ]
        )
        let publicHint = try publicRelayHint()
        let privateHint = try tailscaleHint()
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(
                publicPaths: [publicHint],
                privateFallbackPaths: [privateHint]
            ),
            credential: credential
        )

        await #expect(throws: CmxIrohPrivateFallbackValidationError.unavailable) {
            try await session.connect()
        }

        let dialed = await endpoint.observedDialedAddresses()
        #expect(dialed.map(\.pathHints) == [[publicHint]])
    }

    @Test
    func failedPrivateFallbackRevalidationPreventsItsDial() async throws {
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [
                .failure(.unsupported),
                .failure(.unsupported),
            ]
        )
        let publicHint = try publicRelayHint()
        let privateHint = try tailscaleHint()
        let authorization = try privateFallbackAuthorization(for: [privateHint])
        let validator = TestPrivateFallbackValidator(error: .generationChanged)
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(
                publicPaths: [publicHint],
                privateFallbackPaths: [privateHint]
            ),
            credential: credential,
            privateFallbackAuthorization: authorization,
            privateFallbackValidator: validator
        )

        await #expect(throws: CmxIrohPrivateFallbackValidationError.generationChanged) {
            try await session.connect()
        }

        let dialed = await endpoint.observedDialedAddresses()
        #expect(dialed.map(\.pathHints) == [[publicHint]])
        #expect(await validator.observedAuthorizations() == [authorization])
    }

    @Test
    func mismatchedTLSIdentityClosesBeforeOpeningAControlStream() async throws {
        let attackerIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ef", count: 32)
        )
        let connection = TestIrohConnection(
            remoteIdentity: attackerIdentity,
            bidirectionalStreams: []
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )

        await #expect(throws: CmxIrohClientSessionError.remoteIdentityMismatch) {
            try await session.connect()
        }
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func deniedAdmissionClosesTheWholeConnection() async throws {
        let control = controlStream(decision: .denied(code: 7))
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )

        await #expect(throws: CmxIrohClientSessionError.admissionDenied(code: 7)) {
            try await session.connect()
        }
        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 0)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func deniedAdmissionNeverCreatesAPrivateFallbackConnection() async throws {
        let denied = controlStream(decision: .denied(code: 7))
        let deniedConnection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [denied.stream]
        )
        let replacement = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [controlStream(decision: .accepted).stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [
                .connection(deniedConnection),
                .connection(replacement),
            ]
        )
        let publicHint = try publicRelayHint()
        let privateHint = try tailscaleHint()
        let authorization = try privateFallbackAuthorization(for: [privateHint])
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(
                publicPaths: [publicHint],
                privateFallbackPaths: [privateHint]
            ),
            credential: credential,
            privateFallbackAuthorization: authorization,
            privateFallbackValidator: TestPrivateFallbackValidator()
        )

        await #expect(throws: CmxIrohClientSessionError.admissionDenied(code: 7)) {
            try await session.connect()
        }

        #expect(await endpoint.observedDialedAddresses().map(\.pathHints) == [[publicHint]])
        #expect(await deniedConnection.observedNatTraversalAuthorizationAttemptCount() == 0)
        #expect(await replacement.observedBidirectionalStreamOpenCount() == 0)
    }

    @Test
    func natTraversalAuthorizationFailureSendsNoReadyAckAndCloses() async throws {
        let control = controlStream(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream],
            natTraversalAuthorizationError: .natTraversalAuthorizationFailed
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )

        await #expect(throws: TestIrohTransportError.natTraversalAuthorizationFailed) {
            try await session.connect()
        }

        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 1)
        #expect(await connection.observedNatTraversalActivationCount() == 0)
        #expect(await control.send.observedSentBuffers().count == 1)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func missingServerReadyFailsBeforeAnyApplicationLaneCanOpen() async throws {
        let control = controlStream(
            decision: .accepted,
            serverConfirmationStatus: nil
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )

        await #expect(throws: CmxIrohClientSessionError.unexpectedEndOfStream) {
            try await session.connect()
        }
        await #expect(throws: CmxIrohClientSessionError.notConnected) {
            _ = try await session.openBidirectionalLane(
                .artifact(resourceID: CmxIrohResourceID("artifact:blocked"), offset: 0),
                priority: 1
            )
        }

        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 1)
        #expect(await connection.observedBidirectionalStreamOpenCount() == 1)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func roleInvalidServerConfirmationFailsClosed() async throws {
        let control = controlStream(
            decision: .accepted,
            serverConfirmationStatus: 2
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )

        await #expect(throws: CmxIrohClientSessionError.invalidAdmissionFrame) {
            try await session.connect()
        }

        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 1)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    func controlStream(
        decision: CmxIrohAdmissionDecision,
        acceptedFrame: CmxIrohAdmissionFrame = .acceptedPendingNatTraversal,
        trailingBytes: Data = Data(),
        serverConfirmationStatus: UInt8? = 3,
        eventRecorder: TestIrohEventRecorder? = nil
    ) -> (stream: CmxIrohBidirectionalStream, send: TestIrohSendStream) {
        let finalFrame = if decision == .accepted, let serverConfirmationStatus {
            admissionFrame(status: serverConfirmationStatus)
        } else {
            Data()
        }
        let initialFrame = switch decision {
        case .accepted:
            CmxIrohAdmissionAckCodec().encodeFrame(acceptedFrame)
        case .denied:
            CmxIrohAdmissionAckCodec().encode(decision)
        }
        let receive = TestIrohReceiveStream(
            buffer: initialFrame + finalFrame + trailingBytes
        )
        let send = TestIrohSendStream(
            eventRecorder: eventRecorder,
            eventName: "control.send"
        )
        return (
            CmxIrohBidirectionalStream(receiveStream: receive, sendStream: send),
            send
        )
    }

    func admissionFrame(status: UInt8, code: UInt16 = 0) -> Data {
        var frame = Data("CMXA".utf8)
        frame.append(1)
        frame.append(status)
        let bigEndian = code.bigEndian
        withUnsafeBytes(of: bigEndian) { frame.append(contentsOf: $0) }
        return frame
    }

    func publicRelayHint() throws -> CmxIrohPathHint {
        try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
            source: .native,
            privacyScope: .publicInternet
        )
    }

    func tailscaleHint() throws -> CmxIrohPathHint {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        return try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.64.0.8:4242",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(30 * 60),
            networkProfile: CmxIrohNetworkProfileKey(
                source: .tailscale,
                profileID: String(repeating: "a", count: 64)
            )
        )
    }

}
