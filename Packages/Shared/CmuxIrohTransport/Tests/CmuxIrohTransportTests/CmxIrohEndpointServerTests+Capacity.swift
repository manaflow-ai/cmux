import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohEndpointServerTests {
    @Test
    func fullServerReservesOnePendingReconnectForAnActiveIdentity() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "8", count: 64)
        )
        let activeIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "9", count: 64)
        )
        let newIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 7, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        _ = try await supervisor.activate()
        let started = EndpointServerRecorder()
        let admitted = EndpointServerRecorder()
        let replacementAuthorization = EndpointServerHandlerBlocker()
        let connectionLifetime = EndpointServerHandlerBlocker()
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumConnections: 1,
            maximumConnectionsPerIdentity: 1
        ) { connection, generation, markAdmitted in
            let identity = await connection.remoteIdentity()
            await started.record(identity: identity, generation: generation)
            if await started.recordedCount() == 2 {
                await replacementAuthorization.wait()
            }
            #expect(await markAdmitted())
            await admitted.record(identity: identity, generation: generation)
            await connectionLifetime.wait()
        }
        let active = TestIrohConnection(
            remoteIdentity: activeIdentity,
            bidirectionalStreams: []
        )
        let replacement = TestIrohConnection(
            remoteIdentity: activeIdentity,
            bidirectionalStreams: []
        )
        let newcomer = TestIrohConnection(
            remoteIdentity: newIdentity,
            bidirectionalStreams: []
        )
        var activeCloses = await active.closeEvents().makeAsyncIterator()
        var newcomerCloses = await newcomer.closeEvents().makeAsyncIterator()

        await server.start()
        await endpoint.enqueue(active)
        #expect(await started.next().identity == activeIdentity)
        #expect(await admitted.next().identity == activeIdentity)

        await endpoint.enqueue(replacement)
        for _ in 0 ..< 100 {
            let startedCount = await started.recordedCount()
            let replacementCloseCount = await replacement.observedCloseCallCount()
            guard startedCount < 2, replacementCloseCount == 0 else { break }
            await Task.yield()
        }
        let replacementStarted = await started.recordedCount() == 2
        #expect(replacementStarted)
        guard replacementStarted else {
            await connectionLifetime.releaseAll()
            await server.stop()
            await supervisor.deactivate()
            return
        }
        #expect(await active.observedCloseCallCount() == 0)

        await endpoint.enqueue(newcomer)
        await newcomer.waitUntilClosed()
        let newcomerClose = try #require(await newcomerCloses.next())
        #expect(newcomerClose.reason == "connection_capacity")

        await replacementAuthorization.releaseAll()
        #expect(await admitted.next().identity == activeIdentity)
        let activeClose = try #require(await activeCloses.next())
        #expect(activeClose.reason == "superseded_connection")
        #expect(await replacement.observedCloseCallCount() == 0)

        await connectionLifetime.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func oneEndpointIdentityCannotConsumeEveryPendingAdmissionSlot() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "e", count: 64)
        )
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "f", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 3, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        _ = try await supervisor.activate()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumPendingAdmissions: 3
        ) { connection, generation, _ in
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            if await recorder.recordedCount() == 1 {
                await blocker.wait()
            } else {
                await connection.close(errorCode: 0, reason: "handler_accepted")
            }
        }
        let first = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        let duplicate = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        var duplicateCloses = await duplicate.closeEvents().makeAsyncIterator()

        await server.start()
        await endpoint.enqueue(first)
        #expect(await recorder.next().identity == remoteIdentity)
        await endpoint.enqueue(duplicate)

        let close = try #require(await duplicateCloses.next())
        #expect(close.reason == "admission_identity_capacity")

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func sameEndpointReconnectsDoNotConsumeEveryLiveConnectionSlot() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "1", count: 64)
        )
        let firstRemoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "2", count: 64)
        )
        let secondRemoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "3", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 5, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        _ = try await supervisor.activate()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(supervisor: supervisor) {
            connection,
            generation,
            markAdmitted in
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            #expect(await markAdmitted())
            await blocker.wait()
        }

        await server.start()
        var reconnects: [TestIrohConnection] = []
        for _ in 0 ..< 3 {
            let reconnect = TestIrohConnection(
                remoteIdentity: firstRemoteIdentity,
                bidirectionalStreams: []
            )
            reconnects.append(reconnect)
            await endpoint.enqueue(reconnect)
            #expect(await recorder.next().identity == firstRemoteIdentity)
            if reconnects.count > 1 {
                await reconnects[reconnects.count - 2].waitUntilClosed()
            }
        }
        #expect(await reconnects[0].observedCloseCallCount() == 1)
        #expect(await reconnects[1].observedCloseCallCount() == 1)
        #expect(await reconnects[2].observedCloseCallCount() == 0)
        #expect(await recorder.recordedCount() == 3)

        await endpoint.enqueue(
            TestIrohConnection(
                remoteIdentity: secondRemoteIdentity,
                bidirectionalStreams: []
            )
        )
        #expect(await recorder.next().identity == secondRemoteIdentity)

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }

    @Test
    func failedReplacementAdmissionDoesNotCloseTheActiveConnection() async throws {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "4", count: 64)
        )
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "5", count: 64)
        )
        let endpoint = TestAcceptingIrohEndpoint(identity: localIdentity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 6, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: []
            )
        )
        _ = try await supervisor.activate()
        let blocker = EndpointServerHandlerBlocker()
        let recorder = EndpointServerRecorder()
        let server = CmxIrohEndpointServer(supervisor: supervisor) {
            connection,
            generation,
            markAdmitted in
            await recorder.record(
                identity: await connection.remoteIdentity(),
                generation: generation
            )
            if await recorder.recordedCount() == 1 {
                #expect(await markAdmitted())
                await blocker.wait()
            }
        }
        let active = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )
        let rejectedReplacement = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: []
        )

        await server.start()
        await endpoint.enqueue(active)
        #expect(await recorder.next().identity == remoteIdentity)
        await endpoint.enqueue(rejectedReplacement)
        #expect(await recorder.next().identity == remoteIdentity)
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(await active.observedCloseCallCount() == 0)
        #expect(await rejectedReplacement.observedCloseCallCount() == 1)

        await blocker.releaseAll()
        await server.stop()
        await supervisor.deactivate()
    }
}
