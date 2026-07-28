import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientSessionPoolSingleFlightTests {
    @Test
    func deadOnArrivalDialIsNeverInstalledOrReturnedAndRedialsFresh() async throws {
        let fixture = try SingleFlightPoolFixture()
        let connection1 = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        await connection1.close(errorCode: 0, reason: "pre_dead")
        let connection2 = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(connection1),
                .connection(connection2),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let transport = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)

        try await transport.connect()

        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await connection1.observedCloseCallCount() >= 2)
        #expect(await connection2.observedCloseCallCount() == 0)
        await transport.close()
        #expect(await connection2.observedCloseCallCount() == 1)
        await pool.deactivate()
    }

    @Test
    func concurrentAcquirersCoalesceOntoOneInFlightDial() async throws {
        let fixture = try SingleFlightPoolFixture()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestGatedDialEndpoint(localIdentity: fixture.localIdentity)
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let tasks = (0 ..< 4).map { _ in
            Task {
                try await pool.session(for: fixture.request)
            }
        }

        let reachedDial = await waitForDialCount(endpoint, atLeast: 1)
        #expect(reachedDial)
        for _ in 0 ..< 200 {
            await Task.yield()
            #expect(await endpoint.observedDialCount() == 1)
        }
        await endpoint.releaseNextDial(with: connection)

        let first = try await tasks[0].value
        for task in tasks.dropFirst() {
            #expect(try await task.value === first)
        }
        #expect(await endpoint.observedDialCount() == 1)
        await pool.deactivate()
        await endpoint.close()
    }

    @Test
    func generationBumpDrainsCancelledDialBeforeRedialing() async throws {
        let fixture = try SingleFlightPoolFixture()
        let connection1 = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let connection2 = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestGatedDialEndpoint(localIdentity: fixture.localIdentity)
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
        for _ in 0 ..< 200 {
            await Task.yield()
            #expect(await endpoint.observedDialCount() == 1)
        }

        await endpoint.releaseNextDial(with: connection1)
        #expect(await waitForCloseCount(connection1, atLeast: 1))
        #expect(await waitForDialCount(endpoint, atLeast: 2))
        await endpoint.releaseNextDial(with: connection2)
        try await connect2.value

        let firstConnectSucceeded: Bool
        do {
            try await connect1.value
            firstConnectSucceeded = true
        } catch {
            firstConnectSucceeded = false
        }
        #expect(!firstConnectSucceeded)
        #expect(await connection1.observedCloseCallCount() == 1)
        #expect(await connection2.observedCloseCallCount() == 0)
        await transport2.close()
        await pool.deactivate()
        await endpoint.close()
    }

    // Commit 2: this test depends on the pool's new injected clock parameter.
    @Test
    func wedgedRetiredDialDoesNotBlockRedialPastTheSettleBound() async throws {
        let fixture = try SingleFlightPoolFixture()
        let connection2 = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestGatedDialEndpoint(localIdentity: fixture.localIdentity)
        let pool = try await fixture.pool(
            endpoint: endpoint,
            generation: 1,
            clock: ImmediateHostActivationClock()
        )
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
        await endpoint.releaseNewestDial(with: connection2)
        try await connect2.value

        #expect(await connection2.observedCloseCallCount() == 0)
        connect1.cancel()
        await endpoint.close()
        _ = try? await connect1.value
        await transport2.close()
        await pool.deactivate()
    }

    private func waitForDialCount(
        _ endpoint: TestGatedDialEndpoint,
        atLeast expectedCount: Int
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if await endpoint.observedDialCount() >= expectedCount { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForCloseCount(
        _ connection: TestIrohConnection,
        atLeast expectedCount: Int
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if await connection.observedCloseCallCount() >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

private struct SingleFlightPoolFixture {
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
                id: "iroh-pool-single-flight",
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
        generation: UInt64,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
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
            clock: clock
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
