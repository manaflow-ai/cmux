import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohEndpointServerTests {
    @Test
    func fullServerRejectsReconnectCandidateWithoutDisruptingActiveConnection() async throws {
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
        let connectionLifetime = EndpointServerHandlerBlocker()
        let server = CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumConnections: 1,
            maximumConnectionsPerIdentity: 1
        ) { connection, generation, markAdmitted in
            let identity = await connection.remoteIdentity()
            #expect(await markAdmitted())
            // Publish readiness only after the connection moved out of pending
            // admission. Otherwise the replacement races that transition and
            // tests the per-identity pending limit instead of full capacity.
            await started.record(identity: identity, generation: generation)
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
        var replacementCloses = await replacement.closeEvents().makeAsyncIterator()
        var newcomerCloses = await newcomer.closeEvents().makeAsyncIterator()

        await server.start()
        await endpoint.enqueue(active)
        #expect(await started.next().identity == activeIdentity)

        await endpoint.enqueue(replacement)
        for _ in 0 ..< 100 {
            let startedCount = await started.recordedCount()
            let replacementCloseCount = await replacement.observedCloseCallCount()
            guard startedCount == 1, replacementCloseCount == 0 else { break }
            await Task.yield()
        }
        #expect(await started.recordedCount() == 1)
        let replacementCloseCount = await replacement.observedCloseCallCount()
        #expect(replacementCloseCount == 1)
        if replacementCloseCount == 1 {
            let replacementClose = try #require(await replacementCloses.next())
            #expect(replacementClose.reason == "connection_capacity")
        }
        #expect(await active.observedCloseCallCount() == 0)

        await endpoint.enqueue(newcomer)
        await newcomer.waitUntilClosed()
        let newcomerClose = try #require(await newcomerCloses.next())
        #expect(newcomerClose.reason == "connection_capacity")

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
    func sameEndpointReconnectsReplaceOldestUnreadyConnectionAtBound() async throws {
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
        let first = TestIrohConnection(
            remoteIdentity: firstRemoteIdentity,
            bidirectionalStreams: []
        )
        let replacement = TestIrohConnection(
            remoteIdentity: firstRemoteIdentity,
            bidirectionalStreams: []
        )
        let excessCandidate = TestIrohConnection(
            remoteIdentity: firstRemoteIdentity,
            bidirectionalStreams: []
        )
        var firstCloses = await first.closeEvents().makeAsyncIterator()

        await endpoint.enqueue(first)
        #expect(await recorder.next().identity == firstRemoteIdentity)
        await endpoint.enqueue(replacement)
        #expect(await recorder.next().identity == firstRemoteIdentity)
        await endpoint.enqueue(excessCandidate)
        for _ in 0 ..< 100 {
            let recordedCount = await recorder.recordedCount()
            let firstCloseCount = await first.observedCloseCallCount()
            if recordedCount == 3, firstCloseCount == 1 { break }
            await Task.yield()
        }

        #expect(await recorder.recordedCount() == 3)
        #expect(await recorder.next().identity == firstRemoteIdentity)
        #expect(await first.observedCloseCallCount() == 1)
        #expect(await replacement.observedCloseCallCount() == 0)
        #expect(await excessCandidate.observedCloseCallCount() == 0)
        let firstCloseCount = await first.observedCloseCallCount()
        if firstCloseCount == 1 {
            let close = try #require(await firstCloses.next())
            #expect(close.reason == "superseded_unready_connection")
        }

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
