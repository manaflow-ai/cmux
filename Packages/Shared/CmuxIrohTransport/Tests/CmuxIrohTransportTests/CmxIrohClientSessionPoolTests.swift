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
        await transport.close()
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
        await pool.deactivate()
        #expect(await connection.observedCloseCallCount() == 1)
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
        generation: UInt64
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
            contextProvider: TestIrohClientContextProvider(context: context)
        )
        await pool.activate(runtimeGeneration: generation)
        return pool
    }

    func controlStream() -> CmxIrohBidirectionalStream {
        CmxIrohBidirectionalStream(
            receiveStream: TestIrohReceiveStream(
                buffer: CmxIrohAdmissionAckCodec().encode(.accepted)
            ),
            sendStream: TestIrohSendStream()
        )
    }
}
