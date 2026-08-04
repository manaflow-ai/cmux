import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientSessionPoolCancellationTests {
    @Test
    func retiredDialSettlesViaCancellationNotTheDeadManBound() async throws {
        let fixture = try CancellationPoolFixture()
        let connection2 = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestCancellableDialEndpoint(
            localIdentity: fixture.localIdentity
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        let transport1 = try factory.makeTransport(for: fixture.request)
        let connect1 = Task {
            try await transport1.connect()
        }

        #expect(await waitForDialCount(endpoint, atLeast: 1))
        await pool.activate(runtimeGeneration: 2)

        let transport2 = try factory.makeTransport(for: fixture.request)
        let connect2 = Task {
            try await transport2.connect()
        }
        #expect(await waitForDialCount(endpoint, atLeast: 2))
        await endpoint.releaseNextDial(with: connection2)
        try await connect2.value

        let connect1Result = await connect1.result
        if case .success = connect1Result {
            Issue.record("The retired dial unexpectedly succeeded")
        }
        #expect(await endpoint.observedDeliveredConnectionCount() == 1)
        #expect(await connection2.observedCloseCallCount() == 0)

        await transport2.close()
        await pool.deactivate()
        await endpoint.close()
    }

    @Test
    func cancelledDialBurstYieldsExactlyOneEstablishedSession() async throws {
        let fixture = try CancellationPoolFixture()
        let goodConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestCancellableDialEndpoint(
            localIdentity: fixture.localIdentity
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        var cancelledConnects: [Task<Void, any Error>] = []

        for index in 1 ... 3 {
            let transport = try factory.makeTransport(for: fixture.request)
            let connect = Task {
                try await transport.connect()
            }
            cancelledConnects.append(connect)
            #expect(await waitForDialCount(endpoint, atLeast: index))
            await pool.activate(runtimeGeneration: UInt64(index) + 1)
        }

        let finalTransport = try factory.makeTransport(for: fixture.request)
        let finalConnect = Task {
            try await finalTransport.connect()
        }
        #expect(await waitForDialCount(endpoint, atLeast: 4))
        await endpoint.releaseNextDial(with: goodConnection)
        try await finalConnect.value

        for connect in cancelledConnects {
            if case .success = await connect.result {
                Issue.record("A retired burst dial unexpectedly succeeded")
            }
        }
        #expect(await endpoint.observedDialCount() == 4)
        #expect(await endpoint.observedDeliveredConnectionCount() == 1)
        #expect(await goodConnection.observedCloseCallCount() == 0)

        _ = try await pool.session(for: fixture.request)
        #expect(await endpoint.observedDialCount() == 4)

        await finalTransport.close()
        await pool.deactivate()
        await endpoint.close()
    }

    /// Bounded 1ms-sleep poll: unlike a yield loop, real suspension guarantees
    /// the dial task gets scheduled even when parallel suites saturate the
    /// cooperative pool, while still failing cleanly if the dial never starts.
    private func waitForDialCount(
        _ endpoint: TestCancellableDialEndpoint,
        atLeast expectedCount: Int
    ) async -> Bool {
        for _ in 0 ..< 2_000 {
            if await endpoint.observedDialCount() >= expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private struct CancellationPoolFixture {
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
                id: "iroh-pool-cancellation",
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
        endpoint: any CmxIrohEndpoint,
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
            contextProvider: TestIrohClientContextProvider(context: context),
            protocolConfiguration: .testApplicationLanes,
            clock: ParkingRelayClock()
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
