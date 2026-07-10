import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientSessionTests {
    private let localIdentity: CmxIrohPeerIdentity
    private let remoteIdentity: CmxIrohPeerIdentity
    private let credential: CmxIrohAdmissionCredential

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

        #expect(await connection.observedIncomingStreamLimits() == ["0:0", "0:16"])
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
        #expect(decodedHeader == (try CmxIrohStreamHeader(lane: .control, credential: credential)))
        #expect(clientReady == admissionFrame(status: 2))
        #expect(await events.observedEvents() == [
            "connection.limits:0:0",
            "connection.openBidirectionalStream",
            "control.send",
            "connection.authorizeNatTraversal",
            "control.send",
            "connection.limits:0:16",
        ])
        #expect(try await session.receiveControl() == Data("rpc".utf8))
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
            includesServerReady: false
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
    func terminalLaneGetsIndependentHeaderAndPriority() async throws {
        let control = controlStream(decision: .accepted)
        let terminalReceive = TestIrohReceiveStream(buffer: Data())
        let terminalSend = TestIrohSendStream()
        let terminalStream = CmxIrohBidirectionalStream(
            receiveStream: terminalReceive,
            sendStream: terminalSend
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream, terminalStream]
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
        let lane = CmxIrohLane.terminal(
            resourceID: try CmxIrohResourceID("terminal:42"),
            cursor: 9
        )

        _ = try await session.openBidirectionalLane(lane, priority: 50)

        #expect(await terminalSend.observedPriorities() == [50])
        let sent = await terminalSend.observedSentBuffers()
        #expect(sent.count == 1)
        #expect(try CmxIrohStreamHeaderCodec().decodePrefix(sent[0]).header.lane == lane)
    }

    @Test
    func inboundArtifactHeaderIsRemovedWithoutDroppingPayload() async throws {
        let control = controlStream(decision: .accepted)
        let artifactLane = CmxIrohLane.artifact(
            resourceID: try CmxIrohResourceID("artifact:preview"),
            offset: 128
        )
        let artifactHeader = try CmxIrohStreamHeaderCodec().encode(
            CmxIrohStreamHeader(lane: artifactLane)
        )
        let artifactPayload = Data("preview".utf8)
        let artifactReceive = TestIrohReceiveStream(
            buffer: artifactHeader + artifactPayload
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream],
            receiveStreams: [artifactReceive]
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

        let inbound = try await session.acceptInboundStream()

        #expect(inbound.lane == artifactLane)
        #expect(try await inbound.receiveStream.receive(maximumByteCount: 64) == artifactPayload)
    }

    @Test
    func cancellingConnectCancelsTheUnderlyingIrohDial() async throws {
        let endpoint = TestHangingDialEndpoint(localIdentity: localIdentity)
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )
        var started = await endpoint.startedEvents().makeAsyncIterator()
        var cancelled = await endpoint.cancelledEvents().makeAsyncIterator()
        let connection = Task { try await session.connect() }
        _ = await started.next()

        connection.cancel()

        _ = await cancelled.next()
        await #expect(throws: CancellationError.self) {
            try await connection.value
        }
    }

    private func controlStream(
        decision: CmxIrohAdmissionDecision,
        trailingBytes: Data = Data(),
        includesServerReady: Bool = true,
        eventRecorder: TestIrohEventRecorder? = nil
    ) -> (stream: CmxIrohBidirectionalStream, send: TestIrohSendStream) {
        let finalFrame = if decision == .accepted, includesServerReady {
            admissionFrame(status: 3)
        } else {
            Data()
        }
        let receive = TestIrohReceiveStream(
            buffer: CmxIrohAdmissionAckCodec().encode(decision) + finalFrame + trailingBytes
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

    private func admissionFrame(status: UInt8, code: UInt16 = 0) -> Data {
        var frame = Data("CMXA".utf8)
        frame.append(1)
        frame.append(status)
        let bigEndian = code.bigEndian
        withUnsafeBytes(of: bigEndian) { frame.append(contentsOf: $0) }
        return frame
    }

    private func publicRelayHint() throws -> CmxIrohPathHint {
        try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
            source: .native,
            privacyScope: .publicInternet
        )
    }

    private func tailscaleHint() throws -> CmxIrohPathHint {
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

    private func privateFallbackAuthorization(
        for hints: [CmxIrohPathHint]
    ) throws -> CmxIrohPrivateFallbackAuthorization {
        let profiles = Set(hints.compactMap(\.networkProfile))
        let admittedAt = hints.compactMap(\.observedAt).min()?.addingTimeInterval(1) ?? Date()
        return try CmxIrohPrivateFallbackAuthorization(
            networkPathSnapshot: CmxIrohNetworkPathSnapshot(
                generation: 7,
                activeNetworkProfiles: profiles
            ),
            pathHints: hints,
            admittedAt: admittedAt
        )
    }
}

private actor TestPrivateFallbackValidator: CmxIrohPrivateFallbackValidating {
    private let error: CmxIrohPrivateFallbackValidationError?
    private var authorizations: [CmxIrohPrivateFallbackAuthorization] = []

    init(error: CmxIrohPrivateFallbackValidationError? = nil) {
        self.error = error
    }

    func validatePrivateFallback(
        _ authorization: CmxIrohPrivateFallbackAuthorization
    ) throws {
        authorizations.append(authorization)
        if let error {
            throw error
        }
    }

    func observedAuthorizations() -> [CmxIrohPrivateFallbackAuthorization] {
        authorizations
    }
}
