import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientSessionPoolTests {
    @Test
    func controlTransportClosureObservationTracksItsExactConnection() async throws {
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
        let transport = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)

        try await transport.connect()
        let observer = try #require(transport as? any CmxByteTransportClosureObserving)
        let observation = try #require(await observer.transportClosureObservation())
        let closeWaiter = Task {
            await observation.waitUntilClosed()
            return true
        }

        await connection.close(errorCode: 0, reason: "test peer close")

        #expect(await closeWaiter.value)
        await transport.close()
    }

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
    func samePeerRouteVariantWaitsForControlHandoffThenRedials() async throws {
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
        let relayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.com/",
            source: .native,
            privacyScope: .publicInternet
        )
        let routeVariant = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "same-peer-with-fresh-hints",
                kind: .iroh,
                endpoint: .peer(
                    identity: fixture.remoteIdentity,
                    pathHints: [relayHint]
                )
            ),
            expectedPeerDeviceID: fixture.request.expectedPeerDeviceID?.uppercased(),
            authorizationMode: .transportAdmission
        )
        let second = try factory.makeTransport(for: routeVariant)

        try await first.connect()
        let secondConnect = Task {
            try await second.connect()
        }

        try #require(await waitForControlWaiter(pool, request: routeVariant))
        #expect(await endpoint.observedDialedAddresses().count == 1)
        #expect(await firstConnection.observedCloseCallCount() == 0)
        await first.close()
        try await secondConnect.value

        #expect(await firstConnection.observedCloseCallCount() == 1)
        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await secondConnection.observedCloseCallCount() == 0)
        await second.close()
    }

    @Test
    func cancelledControlHandoffDoesNotBlockTheNextOwner() async throws {
        let fixture = try PoolFixture()
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let replacementConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(replacementConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        let first = try factory.makeTransport(for: fixture.request)
        let cancelled = try factory.makeTransport(for: fixture.request)
        let replacement = try factory.makeTransport(for: fixture.request)
        try await first.connect()

        let cancelledConnect = Task { try await cancelled.connect() }
        try #require(await waitForControlWaiter(pool, request: fixture.request))
        cancelledConnect.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledConnect.value
        }

        await first.close()
        try await replacement.connect()
        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await replacementConnection.observedCloseCallCount() == 0)
        await replacement.close()
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
        let diagnosticLog = DiagnosticLog(capacity: 8)
        let pool = try await fixture.pool(
            endpoint: endpoint,
            generation: 1,
            diagnosticLog: diagnosticLog
        )
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

        for _ in 0 ..< 1_000 {
            if await diagnosticLog.processedCount() >= 4 { break }
            await Task.yield()
        }
        let events = await diagnosticLog.snapshot().events
        #expect(events.map(\.code) == [
            .transportSessionLifecycle,
            .transportSessionLifecycle,
            .sessionClosed,
            .transportSessionLifecycle,
        ])
        #expect(events[1].diagnosticSessionLifecycleKind == .remoteClosed)
        #expect(events[1].diagnosticSessionPurpose == .foregroundControl)
        #expect(events[1].diagnosticSessionID == events[2].diagnosticSessionID)
        #expect(events[3].diagnosticSessionID != events[2].diagnosticSessionID)
        await replacement.close()
    }

    @Test
    func knownClosedCachedSessionRedialsWithoutWaitingForClosureWatcher() async throws {
        let fixture = try PoolFixture()
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            reportsClosureToWaiters: false
        )
        let secondConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [
                fixture.controlStream(),
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: Data()),
                    sendStream: TestIrohSendStream()
                ),
            ]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(secondConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let control = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        try await control.connect()
        await firstConnection.close(errorCode: 99, reason: "timed_out")

        _ = try await pool.openBidirectionalLane(
            for: fixture.request,
            lane: .terminal(
                resourceID: CmxIrohResourceID("terminal:known-closed"),
                cursor: nil
            ),
            priority: 50
        )

        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await secondConnection.observedBidirectionalStreamOpenCount() == 2)
        await pool.deactivate()
    }

    @Test
    func concurrentLaneOpenFailureCoalescesOneAuthenticatedReplacementDial() async throws {
        let fixture = try PoolFixture()
        let concurrentLaneCount = 8
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            bidirectionalStreamFailureNumber: 2,
            reportsClosureToWaiters: false
        )
        let replacementLaneStreams = (0 ..< concurrentLaneCount).map { _ in
            CmxIrohBidirectionalStream(
                receiveStream: TestIrohReceiveStream(buffer: Data()),
                sendStream: TestIrohSendStream()
            )
        }
        let secondConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()] + replacementLaneStreams
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(secondConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let control = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        try await control.connect()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< concurrentLaneCount {
                group.addTask {
                    _ = try await pool.openBidirectionalLane(
                        for: fixture.request,
                        lane: .terminal(
                            resourceID: CmxIrohResourceID("terminal:\(index)"),
                            cursor: UInt64(index)
                        ),
                        priority: Int32(index)
                    )
                }
            }
            try await group.waitForAll()
        }

        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(
            await secondConnection.observedBidirectionalStreamOpenCount()
                == concurrentLaneCount + 1
        )
        await pool.deactivate()
    }

    @Test
    func laneFailureReplacementRevalidatesEndpointIdentity() async throws {
        let fixture = try PoolFixture()
        let substitutedIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ef", count: 32)
        )
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            bidirectionalStreamFailureNumber: 2,
            reportsClosureToWaiters: false
        )
        let substitutedConnection = TestIrohConnection(
            remoteIdentity: substitutedIdentity,
            bidirectionalStreams: [fixture.controlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(substitutedConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let control = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        try await control.connect()

        await #expect(throws: CmxIrohClientSessionError.remoteIdentityMismatch) {
            _ = try await pool.openBidirectionalLane(
                for: fixture.request,
                lane: .terminal(
                    resourceID: CmxIrohResourceID("terminal:substitution"),
                    cursor: nil
                ),
                priority: 0
            )
        }

        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await substitutedConnection.observedCloseCallCount() == 1)
        await pool.deactivate()
    }

    @Test
    func lateOldControlOwnerReleaseDoesNotCloseLaneReplacement() async throws {
        let fixture = try PoolFixture()
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            reportsClosureToWaiters: false
        )
        let secondConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [
                fixture.controlStream(),
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: Data()),
                    sendStream: TestIrohSendStream()
                ),
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: Data()),
                    sendStream: TestIrohSendStream()
                ),
            ]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(secondConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let oldControl = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        try await oldControl.connect()
        await firstConnection.close(errorCode: 99, reason: "timed_out")

        _ = try await pool.openBidirectionalLane(
            for: fixture.request,
            lane: .terminal(
                resourceID: CmxIrohResourceID("terminal:first"),
                cursor: nil
            ),
            priority: 0
        )
        await oldControl.close()
        _ = try await pool.openBidirectionalLane(
            for: fixture.request,
            lane: .terminal(
                resourceID: CmxIrohResourceID("terminal:second"),
                cursor: nil
            ),
            priority: 0
        )

        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await secondConnection.observedCloseCallCount() == 0)
        await pool.deactivate()
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

    @Test
    func selectedPathDoesNotPublishAnUnestablishedControlSession() async throws {
        let fixture = try PoolFixture()
        let endpoint = TestHangingDialEndpoint(localIdentity: fixture.localIdentity)
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let changes = await pool.selectedPathChanges()
        let recorder = SelectedPathChangeRecorder()
        let observation = Task {
            for await _ in changes {
                await recorder.record()
            }
        }
        #expect(await waitForSelectedPathChangeCount(recorder, atLeast: 1))

        let transport = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        let connection = Task {
            try await transport.connect()
        }
        let started = await endpoint.startedEvents()
        var startedIterator = started.makeAsyncIterator()
        #expect(await startedIterator.next() != nil)

        let publishedBeforeEstablishment = await waitForSelectedPathChangeCount(
            recorder,
            atLeast: 2
        )
        #expect(!publishedBeforeEstablishment)
        #expect(await pool.selectedObservedPath() == .unavailable)

        connection.cancel()
        await pool.deactivate()
        _ = try? await connection.value
        observation.cancel()
    }

    @Test
    func selectedPathPrefersTheActiveControlSessionOverANewerBackgroundSession() async throws {
        let fixture = try PoolFixture()
        let backgroundIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ef", count: 32)
        )
        let backgroundRequest = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh-background-session",
                kind: .iroh,
                endpoint: .peer(identity: backgroundIdentity, pathHints: [])
            ),
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174031",
            authorizationMode: .transportAdmission,
            sessionPurpose: .backgroundControl
        )
        let controlConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            selectedPath: .direct
        )
        let backgroundConnection = TestIrohConnection(
            remoteIdentity: backgroundIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            selectedPath: .relay(url: "https://relay.example.com/")
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(controlConnection),
                .connection(backgroundConnection),
            ]
        )
        let pool = try await fixture.pool(endpoint: endpoint, generation: 1)
        let control = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: fixture.request)
        let background = try CmxIrohByteTransportFactory(sessionPool: pool)
            .makeTransport(for: backgroundRequest)

        try await control.connect()
        #expect(await pool.selectedObservedPath() == .direct)

        try await background.connect()

        #expect(await pool.selectedObservedPath() == .direct)
        await background.close()
        await control.close()
    }

    @Test
    func ownerReleaseExplainsTheExactUnavailableRelayPrivatePathCycle() async throws {
        let fixture = try PoolFixture()
        let firstConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            selectedPath: .privateNetwork
        )
        let replacementConnection = TestIrohConnection(
            remoteIdentity: fixture.remoteIdentity,
            bidirectionalStreams: [fixture.controlStream()],
            selectedPath: .relay(url: "https://relay.example.com/")
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: fixture.localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(replacementConnection),
            ]
        )
        let diagnosticLog = DiagnosticLog(capacity: 16)
        let pool = try await fixture.pool(
            endpoint: endpoint,
            generation: 1,
            diagnosticLog: diagnosticLog
        )
        let changes = await pool.selectedPathChanges()
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)

        let first = try factory.makeTransport(for: fixture.request)
        try await first.connect()
        #expect(await iterator.next() != nil)
        #expect(await pool.selectedObservedPath() == .privateNetwork)

        await first.close()
        #expect(await iterator.next() != nil)
        let unavailable = await pool.selectedObservedPath()

        let replacement = try factory.makeTransport(for: fixture.request)
        try await replacement.connect()
        #expect(await iterator.next() != nil)
        let relay = await pool.selectedObservedPath()

        await replacementConnection.setObservedSelectedPath(.privateNetwork)
        #expect(await iterator.next() != nil)
        let privateNetwork = await pool.selectedObservedPath()

        #expect([unavailable, relay, privateNetwork] == [
            .unavailable,
            .relay(url: "https://relay.example.com/"),
            .privateNetwork,
        ])

        for _ in 0 ..< 1_000 {
            if await diagnosticLog.processedCount() >= 4 { break }
            await Task.yield()
        }
        let events = await diagnosticLog.snapshot().events
        #expect(events.map(\.code) == [
            .transportSessionLifecycle,
            .transportSessionLifecycle,
            .sessionClosed,
            .transportSessionLifecycle,
        ])
        #expect(events.map(\.a) == [
            DiagnosticSessionLifecycleKind.established.rawValue,
            DiagnosticSessionLifecycleKind.controlOwnerReleased.rawValue,
            DiagnosticTransportKind.iroh.rawValue,
            DiagnosticSessionLifecycleKind.established.rawValue,
        ])
        #expect(events[0].b == Int(CmxTransportSessionPurpose.foregroundControl.rawValue))
        #expect(events[1].b == Int(CmxTransportSessionPurpose.foregroundControl.rawValue))
        #expect(events[2].b == DiagnosticFailureKind.none.rawValue)
        #expect(events[0].c == events[1].c)
        #expect(events[1].c == events[2].c)
        #expect(events[3].c != events[2].c)

        await replacement.close()
    }

    @Test
    func mixedCaseBackgroundAliasCannotTearDownTheForegroundControlOwner() async throws {
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
        let factory = CmxIrohByteTransportFactory(sessionPool: pool)
        let foreground = try factory.makeTransport(for: fixture.request)
        let backgroundRequest = CmxByteTransportRequest(
            route: fixture.request.route,
            expectedPeerDeviceID: fixture.request.expectedPeerDeviceID?.uppercased(),
            authorizationMode: .transportAdmission,
            sessionPurpose: .backgroundControl
        )
        let background = try factory.makeTransport(for: backgroundRequest)

        try await foreground.connect()
        let backgroundConnect = Task { try await background.connect() }
        try #require(await waitForControlWaiter(pool, request: backgroundRequest))
        backgroundConnect.cancel()
        await #expect(throws: CancellationError.self) {
            try await backgroundConnect.value
        }

        #expect(await pool.selectedObservedPath() == .privateNetwork)
        #expect(await connection.observedCloseCallCount() == 0)
        #expect(await endpoint.observedDialedAddresses().count == 1)
        await foreground.close()
    }
}

private func waitForControlWaiter(
    _ pool: CmxIrohClientSessionPool,
    request: CmxByteTransportRequest
) async -> Bool {
    for _ in 0 ..< 1_000 {
        if await pool.controlWaiterCount(for: request) == 1 { return true }
        await Task.yield()
    }
    return false
}

private actor SelectedPathChangeRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func observedCount() -> Int {
        count
    }
}

private func waitForSelectedPathChangeCount(
    _ recorder: SelectedPathChangeRecorder,
    atLeast expectedCount: Int
) async -> Bool {
    for _ in 0 ..< 1_000 {
        if await recorder.observedCount() >= expectedCount { return true }
        await Task.yield()
    }
    return false
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
        endpoint: any CmxIrohEndpoint,
        generation: UInt64,
        contextProvider: (any CmxIrohClientContextProvider)? = nil,
        diagnosticLog: DiagnosticLog? = nil
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
            protocolConfiguration: .testApplicationLanes,
            diagnosticLog: diagnosticLog
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
