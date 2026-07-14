import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohEndpointServerTests {
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
