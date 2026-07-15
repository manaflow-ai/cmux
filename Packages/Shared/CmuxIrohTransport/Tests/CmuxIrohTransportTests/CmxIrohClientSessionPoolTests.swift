import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientSessionPoolTests {
    @Test
    func controlAndFeatureLanesReuseOneAdmittedConnection() async throws {
        let fixture = try PoolFixture()
        let control = fixture.controlStream()
        let terminalSend = TestIrohSendStream()
        let artifactSend = TestIrohSendStream()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [
                control,
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: Data()),
                    sendStream: terminalSend
                ),
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: Data()),
                    sendStream: artifactSend
                ),
            ]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [.connection(connection)]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        let transport = try factory.makeTransport(for: fixture.request)

        try await transport.connect()
        _ = try await pool.openBidirectionalLane(
            for: fixture.request,
            lane: .terminal(
                resourceID: CmxIrohResourceID("terminal:42"),
                cursor: 7
            ),
            priority: 50
        )
        _ = try await pool.openBidirectionalLane(
            for: fixture.request,
            lane: .artifact(
                resourceID: CmxIrohResourceID("artifact:preview"),
                offset: 0
            ),
            priority: 10
        )

        #expect(await endpoint.observedDialedAddresses().count == 1)
        #expect(await terminalSend.observedPriorities() == [50])
        #expect(await artifactSend.observedPriorities() == [10])
        #expect(await connection.observedCloseCallCount() == 0)
        await #expect(throws: CmxIrohClientSessionError.invalidOutgoingLane) {
            _ = try await pool.openBidirectionalLane(
                for: fixture.request,
                lane: .control,
                priority: 0
            )
        }
        #expect(await connection.observedCloseCallCount() == 0)
        await transport.close()
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func replacementControlOwnerRedialsInsteadOfReusingFramingState() async throws {
        let fixture = try PoolFixture()
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let secondConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(secondConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        let first = try factory.makeTransport(for: fixture.request)
        try await first.connect()

        await first.close()
        let replacement = try factory.makeTransport(for: fixture.request)
        try await replacement.connect()

        #expect(await firstConnection.observedCloseCallCount() == 1)
        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await secondConnection.observedCloseCallCount() == 0)
        await replacement.close()
    }

    @Test
    func concurrentControlOwnerFailsInsteadOfSharingTheControlReader() async throws {
        let fixture = try PoolFixture()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [.connection(connection)]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        let first = try factory.makeTransport(for: fixture.request)
        let second = try factory.makeTransport(for: fixture.request)

        try await first.connect()
        await #expect(throws: CmxIrohByteTransportError.controlLaneAlreadyOwned) {
            try await second.connect()
        }

        #expect(await endpoint.observedDialedAddresses().count == 1)
        #expect(await connection.observedCloseCallCount() == 0)
        await first.close()
    }

    @Test
    func remoteConnectionCloseEvictsPooledSessionBeforeRedial() async throws {
        let fixture = try PoolFixture()
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let secondConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(secondConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        let first = try factory.makeTransport(for: fixture.request)
        try await first.connect()
        for _ in 0 ..< 100 { await Task.yield() }

        await firstConnection.close(errorCode: 99, reason: "peer_closed")
        for _ in 0 ..< 100 { await Task.yield() }

        let replacement = try factory.makeTransport(for: fixture.request)
        try await replacement.connect()
        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await secondConnection.observedCloseCallCount() == 0)
        await replacement.close()
    }

    @Test
    func endpointGenerationChangeClosesOldSessionBeforeRedial() async throws {
        let fixture = try PoolFixture()
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let secondConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(secondConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        let first = try factory.makeTransport(for: fixture.request)
        try await first.connect()

        await pool.activate(runtimeGeneration: 2)

        #expect(await firstConnection.observedCloseCallCount() == 1)
        let second = try factory.makeTransport(for: fixture.request)
        try await second.connect()
        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await secondConnection.observedCloseCallCount() == 0)
        await pool.deactivate()
    }

    @Test
    func pooledSessionStartsPublicThenRefreshesAndValidatesLANFallback() async throws {
        let fixture = try PoolFixture()
        let now = Date()
        let publicHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
            source: .native,
            privacyScope: .publicInternet
        )
        let profile = try CmxIrohNetworkProfileKey(
            source: .lan,
            profileID: String(repeating: "b", count: 64)
        )
        let privateHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "192.168.1.10:50906",
            source: .lan,
            privacyScope: .localNetwork,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60),
            networkProfile: profile
        )
        let authorization = try CmxIrohPrivateFallbackAuthorization(
            networkPathSnapshot: CmxIrohNetworkPathSnapshot(
                generation: 9,
                activeNetworkProfiles: [profile]
            ),
            pathHints: [privateHint],
            admittedAt: now
        )
        let base = CmxIrohClientContext(
            dialPlan: try testIrohDialPlan(publicPaths: [publicHint]),
            credential: fixture.context.credential
        )
        let fallback = CmxIrohClientContext(
            dialPlan: try testIrohDialPlan(
                publicPaths: [publicHint],
                privateFallbackPaths: [privateHint]
            ),
            credential: fixture.context.credential,
            privateFallbackAuthorization: authorization
        )
        let provider = TestIrohClientContextProvider(
            context: base,
            fallbackContext: fallback
        )
        let connection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .failure(.unsupported),
                .connection(connection),
            ]
        )
        let pool = try await fixture.pool(
            endpoint: endpoint,
            generation: 1,
            contextProvider: provider
        )
        let transport = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)

        try await transport.connect()

        #expect(await endpoint.observedDialedAddresses().map(\.pathHints) == [
            [publicHint],
            [privateHint],
        ])
        #expect(await provider.observedFallbackRequestCount() == 1)
        #expect(await provider.observedAuthorizations() == [authorization])
        await transport.close()
    }

    @Test
    func selectedPathLifecycleIsEventDrivenAndCoordinateFree() async throws {
        let fixture = try PoolFixture()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            selectedPath: .privateNetwork
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [.connection(connection)]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let changes = await pool.selectedPathChanges()
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)

        let transport = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        try await transport.connect()

        #expect(await iterator.next() != nil)
        #expect(await pool.selectedObservedPath() == .privateNetwork)

        await connection.setObservedSelectedPath(.direct)

        #expect(await iterator.next() != nil)
        #expect(await pool.selectedObservedPath() == .direct)

        await transport.close()

        #expect(await iterator.next() != nil)
        #expect(await pool.selectedObservedPath() == .unavailable)
    }
}

private struct PoolFixture {
    let localIdentity: CmxIrohPeerIdentity
    let remoteIdentity: CmxIrohPeerIdentity
    let request: CmxByteTransportRequest
    let context: CmxIrohClientContext

    init() throws {
        localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32)
        )
        remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "cd", count: 32)
        )
        request = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh-pool",
                kind: .iroh,
                endpoint: .peer(identity: remoteIdentity, pathHints: [])
            ),
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174030",
            authorizationMode: .transportAdmission
        )
        context = CmxIrohClientContext(
            dialPlan: try testIrohDialPlan(),
            credential: try .pairGrant("e30.e30.AA")
        )
    }

    func pool(
        endpoint: TestDialingIrohEndpoint,
        generation: UInt64,
        contextProvider: (any CmxIrohClientContextProvider)? = nil
    ) async throws -> CmxIrohClientSessionPool {
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data(repeating: 7, count: 32)),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            managedRelayURLs: [],
            relays: []
        )
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: configuration
        )
        _ = try await supervisor.activate()
        let pool = CmxIrohClientSessionPool(
            supervisor: supervisor,
            contextProvider: contextProvider
                ?? TestIrohClientContextProvider(context: context),
            protocolConfiguration: .testApplicationLanes
        )
        await pool.activate(runtimeGeneration: generation)
        return pool
    }

    func controlStream() -> CmxIrohBidirectionalStream {
        let admissionCodec = CmxIrohAdmissionAckCodec()
        return CmxIrohBidirectionalStream(
            receiveStream: TestIrohReceiveStream(
                buffer: admissionCodec.encode(.accepted)
                    + admissionCodec.encodeFrame(.serverReady)
            ),
            sendStream: TestIrohSendStream()
        )
    }
}
