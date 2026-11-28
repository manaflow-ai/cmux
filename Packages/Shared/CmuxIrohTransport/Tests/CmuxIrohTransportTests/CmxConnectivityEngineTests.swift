import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

struct CmxConnectivityEngineTests {
    @Test
    func startInstallsOneAuthoritativeSnapshotBeforeBecomingActive() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let endpoint = TestIrohEndpoint(identity: identity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try Self.endpointConfiguration()
        )
        let authority = try GatedConnectivityAuthority(
            changed: Self.changedResponse(revision: 9),
            unchanged: Self.unchangedResponse(revision: 9)
        )
        let installer = ConnectivitySnapshotInstallerRecorder()
        let engine = CmxConnectivityEngine(
            supervisor: supervisor,
            contextProvider: FailingConnectivityContextProvider(),
            authority: authority,
            installRouteSnapshot: { snapshot in
                await installer.install(snapshot)
            }
        )

        let start = Task { try await engine.start() }
        try await Self.waitUntil { await authority.callCount() == 1 }
        #expect(await engine.snapshot().phase == .starting)
        await authority.releaseFirstRequest()
        try await start.value

        let snapshot = await engine.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.endpointGeneration == 1)
        #expect(snapshot.localIdentity == identity)
        #expect(snapshot.routeRevision == 9)
        #expect(await installer.revisions() == [9])
        #expect(await authority.callCount() == 1)
    }

    @Test
    func replacementEndpointReconcilesBeforePublishingTheNewActiveGeneration() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "c", count: 64)
        )
        let firstEndpoint = TestIrohEndpoint(identity: identity)
        let secondEndpoint = TestIrohEndpoint(identity: identity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(
                endpoints: [firstEndpoint, secondEndpoint]
            ),
            configuration: try Self.endpointConfiguration()
        )
        let authority = try GatedConnectivityAuthority(
            changed: Self.changedResponse(revision: 3),
            unchanged: Self.unchangedResponse(revision: 3)
        )
        let engine = CmxConnectivityEngine(
            supervisor: supervisor,
            contextProvider: FailingConnectivityContextProvider(),
            authority: authority,
            installRouteSnapshot: { _ in }
        )
        let start = Task { try await engine.start() }
        try await Self.waitUntil { await authority.callCount() == 1 }
        await authority.releaseFirstRequest()
        try await start.value

        await firstEndpoint.emit(.closedUnexpectedly)
        try await Self.waitUntil {
            let snapshot = await engine.snapshot()
            let callCount = await authority.callCount()
            return snapshot.phase == .active
                && snapshot.endpointGeneration == 2
                && callCount == 2
        }

        #expect(await engine.snapshot().routeRevision == 3)
        await engine.stop()
        #expect(await engine.snapshot().phase == .stopped)
        #expect(await secondEndpoint.observedCloseCallCount() == 1)
    }

    @Test
    func healthyReplacementEndpointRemainsActiveWhenRouteRefreshIsOffline() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "d", count: 64)
        )
        let firstEndpoint = TestIrohEndpoint(identity: identity)
        let secondEndpoint = TestIrohEndpoint(identity: identity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(
                endpoints: [firstEndpoint, secondEndpoint]
            ),
            configuration: try Self.endpointConfiguration()
        )
        let authority = try InitialThenFailingConnectivityAuthority(
            initial: Self.changedResponse(revision: 4)
        )
        let engine = CmxConnectivityEngine(
            supervisor: supervisor,
            contextProvider: FailingConnectivityContextProvider(),
            authority: authority,
            installRouteSnapshot: { _ in }
        )
        try await engine.start()

        await firstEndpoint.emit(.closedUnexpectedly)
        try await Self.waitUntil {
            let snapshot = await engine.snapshot()
            return snapshot.endpointGeneration == 2
                && snapshot.phase != .starting
        }

        let snapshot = await engine.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.routeRevision == 4)
        #expect(await authority.callCount() >= 2)
        await engine.stop()
    }

    @Test
    func endpointConsumerWaitsForUnexpectedClosureRecovery() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "f", count: 64)
        )
        let firstEndpoint = TestIrohEndpoint(identity: identity)
        let replacementEndpoint = TestIrohEndpoint(identity: identity)
        let factory = GatedReplacementEndpointFactory(
            first: firstEndpoint,
            replacement: replacementEndpoint
        )
        let engine = CmxConnectivityEngine(
            factory: factory,
            endpointConfiguration: try Self.endpointConfiguration(),
            contextProvider: FailingConnectivityContextProvider()
        )
        try await engine.start()

        await firstEndpoint.emit(.closedUnexpectedly)
        try await Self.waitUntil {
            let bindCallCount = await factory.bindCallCount()
            let snapshot = await engine.snapshot()
            return bindCallCount == 2 && snapshot.phase == .starting
        }

        let lookupStarted = ConnectivityObservationFlag()
        let lookup = Task {
            await lookupStarted.markFinished()
            return try await engine.localEndpointIdentity()
        }
        try await Self.waitUntil { await lookupStarted.value() }
        for _ in 0 ..< 100 { await Task.yield() }

        await factory.releaseReplacement()

        #expect(try await lookup.value == identity)
        #expect(await engine.snapshot().phase == .active)
        #expect(await engine.snapshot().endpointGeneration == 2)
        await engine.stop()
    }

    @Test
    func equivalentRouteRevisionBumpKeepsTheLivePeerSession() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z"
            ),
            Self.peerRouteResponse(
                revision: 10,
                lastSeenAt: "2026-07-30T00:00:45Z"
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )
        #expect(await session.isClosed() == false)

        try await rig.engine.reconcileRoutes()

        let snapshot = await rig.engine.snapshot()
        #expect(snapshot.routeRevision == 10)
        #expect(await rig.connection.observedCloseCallCount() == 0)
        #expect(await session.isClosed() == false)
        #expect(snapshot.peers.first?.phase == .connected)
        await rig.engine.stop()
    }

    @Test
    func changedIdentityGenerationOnRevisionBumpStillInvalidatesTheSession() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z"
            ),
            Self.peerRouteResponse(
                revision: 10,
                lastSeenAt: "2026-07-30T00:00:45Z",
                identityGeneration: 2
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )

        try await rig.engine.reconcileRoutes()

        #expect(await rig.engine.snapshot().routeRevision == 10)
        #expect(await rig.connection.observedCloseCallCount() == 1)
        #expect(await session.isClosed())
        await rig.engine.stop()
    }

    @Test
    func removedPeerBindingOnRevisionBumpStillInvalidatesTheSession() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z"
            ),
            Self.peerRouteResponse(
                revision: 10,
                lastSeenAt: "2026-07-30T00:00:45Z",
                includesPeerBinding: false
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )

        try await rig.engine.reconcileRoutes()

        #expect(await rig.connection.observedCloseCallCount() == 1)
        #expect(await session.isClosed())
        await rig.engine.stop()
    }

    @Test
    func changedRelayFleetOnRevisionBumpStillInvalidatesTheSession() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z"
            ),
            Self.peerRouteResponse(
                revision: 10,
                lastSeenAt: "2026-07-30T00:00:45Z",
                relayFleet: ["https://replacement.relay.example/"]
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )

        try await rig.engine.reconcileRoutes()

        #expect(await rig.connection.observedCloseCallCount() == 1)
        #expect(await session.isClosed())
        await rig.engine.stop()
    }

    @Test
    func revisionBumpWithoutReplacementContentFailsClosed() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z"
            ),
            Self.unchangedResponse(revision: 12),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )

        try await rig.engine.reconcileRoutes()

        #expect(await rig.engine.snapshot().routeRevision == 12)
        #expect(await rig.connection.observedCloseCallCount() == 1)
        #expect(await session.isClosed())
        await rig.engine.stop()
    }

    @Test
    func installedRouteRevisionUsesRouteContentEquivalence() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z"
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )
        let equivalent = try #require(Self.peerRouteResponse(
            revision: 10,
            lastSeenAt: "2026-07-30T00:00:45Z"
        ).snapshot)
        let changed = try #require(Self.peerRouteResponse(
            revision: 11,
            lastSeenAt: "2026-07-30T00:01:30Z",
            identityGeneration: 2
        ).snapshot)

        await rig.engine.didInstallRouteRevision(10, routes: equivalent)

        #expect(await rig.engine.snapshot().routeRevision == 10)
        #expect(await rig.connection.observedCloseCallCount() == 0)
        #expect(await session.isClosed() == false)

        await rig.engine.didInstallRouteRevision(11, routes: changed)

        #expect(await rig.engine.snapshot().routeRevision == 11)
        #expect(await rig.connection.observedCloseCallCount() == 1)
        #expect(await session.isClosed())
        await rig.engine.stop()
    }

    @Test
    func reorderedCapabilitiesOnRevisionBumpKeepsTheLivePeerSession() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z",
                capabilities: ["artifact", "terminal"]
            ),
            Self.peerRouteResponse(
                revision: 10,
                lastSeenAt: "2026-07-30T00:00:45Z",
                capabilities: ["terminal", "artifact"]
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )

        try await rig.engine.reconcileRoutes()

        #expect(await rig.engine.snapshot().routeRevision == 10)
        #expect(await rig.connection.observedCloseCallCount() == 0)
        #expect(await session.isClosed() == false)
        await rig.engine.stop()
    }

    @Test
    func reorderedRelayFleetOnRevisionBumpKeepsTheLivePeerSession() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z",
                relayFleet: [
                    "https://relay-a.example/",
                    "https://relay-b.example/",
                ]
            ),
            Self.peerRouteResponse(
                revision: 10,
                lastSeenAt: "2026-07-30T00:00:45Z",
                relayFleet: [
                    "https://relay-b.example/",
                    "https://relay-a.example/",
                ]
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )

        try await rig.engine.reconcileRoutes()

        #expect(await rig.engine.snapshot().routeRevision == 10)
        #expect(await rig.connection.observedCloseCallCount() == 0)
        #expect(await session.isClosed() == false)
        await rig.engine.stop()
    }

    @Test
    func reorderedGrantVerificationKeysOnRevisionBumpKeepsTheLivePeerSession() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z",
                grantVerificationKeyIDs: ["current", "previous"]
            ),
            Self.peerRouteResponse(
                revision: 10,
                lastSeenAt: "2026-07-30T00:00:45Z",
                grantVerificationKeyIDs: ["previous", "current"]
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )

        try await rig.engine.reconcileRoutes()

        #expect(await rig.engine.snapshot().routeRevision == 10)
        #expect(await rig.connection.observedCloseCallCount() == 0)
        #expect(await session.isClosed() == false)
        await rig.engine.stop()
    }

    @Test
    func snapshotInstallForARevisionRecordedWithoutContentFailsClosed() async throws {
        let rig = try await Self.admittedPeerRig(
            responses: [
                Self.peerRouteResponse(
                    revision: 9,
                    lastSeenAt: "2026-07-30T00:00:00Z"
                ),
                Self.unchangedResponse(revision: 12),
            ],
            dialableConnections: 2
        )
        let first = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )
        try await rig.engine.reconcileRoutes()
        #expect(await first.isClosed())
        let second = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )
        #expect(await second.isClosed() == false)
        let snapshot = try #require(Self.peerRouteResponse(
            revision: 12,
            lastSeenAt: "2026-07-30T00:00:45Z"
        ).snapshot)

        await rig.engine.didInstallRouteRevision(12, routes: snapshot)

        #expect(await rig.engine.snapshot().routeRevision == 12)
        #expect(await rig.connections[1].observedCloseCallCount() == 1)
        #expect(await second.isClosed())
        await rig.engine.stop()
    }

    @Test
    func sameRevisionReinstallWithUnchangedContentKeepsTheLivePeerSession() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z"
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )
        let snapshot = try #require(Self.peerRouteResponse(
            revision: 10,
            lastSeenAt: "2026-07-30T00:00:45Z"
        ).snapshot)

        await rig.engine.didInstallRouteRevision(10, routes: snapshot)
        await rig.engine.didInstallRouteRevision(10, routes: snapshot)

        #expect(await rig.engine.snapshot().routeRevision == 10)
        #expect(await rig.connection.observedCloseCallCount() == 0)
        #expect(await session.isClosed() == false)
        await rig.engine.stop()
    }

    @Test
    func olderRouteRevisionInstallCannotRollBackANewerInstall() async throws {
        let rig = try await Self.admittedPeerRig(responses: [
            Self.peerRouteResponse(
                revision: 9,
                lastSeenAt: "2026-07-30T00:00:00Z"
            ),
        ])
        let session = try await rig.engine.acquireControl(
            for: rig.request,
            ownerID: UUID()
        )
        let newer = try #require(Self.peerRouteResponse(
            revision: 11,
            lastSeenAt: "2026-07-30T00:00:45Z"
        ).snapshot)
        let older = try #require(Self.peerRouteResponse(
            revision: 10,
            lastSeenAt: "2026-07-30T00:00:30Z",
            identityGeneration: 2
        ).snapshot)

        await rig.engine.didInstallRouteRevision(11, routes: newer)
        await rig.engine.didInstallRouteRevision(10, routes: older)

        #expect(await rig.engine.snapshot().routeRevision == 11)
        #expect(await rig.connection.observedCloseCallCount() == 0)
        #expect(await session.isClosed() == false)
        await rig.engine.stop()
    }

    @Test
    func stopFinishesNetworkChangeObservers() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "e", count: 64)
        )
        let engine = CmxConnectivityEngine(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: identity)]
            ),
            endpointConfiguration: try Self.endpointConfiguration(),
            contextProvider: FailingConnectivityContextProvider()
        )
        try await engine.start()
        let finished = ConnectivityObservationFlag()
        let changes = await engine.networkChanges()
        let observation = Task {
            for await _ in changes {}
            await finished.markFinished()
        }
        defer { observation.cancel() }

        await engine.stop()

        try await Self.waitUntil { await finished.value() }
    }

    private static let peerEndpointID = String(repeating: "f", count: 64)
    private static let peerDeviceID = "123e4567-e89b-42d3-a456-426614174999"

    private struct AdmittedPeerRig {
        let engine: CmxConnectivityEngine
        let connections: [TestIrohConnection]
        let authority: ScriptedConnectivityAuthority
        let request: CmxByteTransportRequest

        var connection: TestIrohConnection { connections[0] }
    }

    private static func admittedPeerRig(
        responses: [CmxConnectivitySyncResponse],
        dialableConnections: Int = 1
    ) async throws -> AdmittedPeerRig {
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "1", count: 64)
        )
        let peerIdentity = try CmxIrohPeerIdentity(endpointID: peerEndpointID)
        let connections = (0 ..< dialableConnections).map { _ in
            TestIrohConnection(
                remoteIdentity: peerIdentity,
                bidirectionalStreams: [CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(
                        buffer: CmxIrohAdmissionAckCodec()
                            .encodeFrame(.acceptedPendingNatTraversal)
                            + admissionFrame(status: 3)
                    ),
                    sendStream: TestIrohSendStream()
                )],
                selectedPath: .direct
            )
        }
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: connections.map { .connection($0) }
        )
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try endpointConfiguration()
        )
        let authority = ScriptedConnectivityAuthority(responses: responses)
        let context = CmxIrohClientContext(
            dialPlan: try testIrohDialPlan(),
            credential: try .pairGrant("e30.e30.AA")
        )
        let engine = CmxConnectivityEngine(
            supervisor: supervisor,
            contextProvider: TestIrohClientContextProvider(context: context),
            authority: authority,
            installRouteSnapshot: { _ in }
        )
        try await engine.start()
        let request = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh-v2",
                kind: .iroh,
                endpoint: .peer(identity: peerIdentity, pathHints: [])
            ),
            expectedPeerDeviceID: peerDeviceID,
            authorizationMode: .transportAdmission
        )
        return AdmittedPeerRig(
            engine: engine,
            connections: connections,
            authority: authority,
            request: request
        )
    }

    private static func peerRouteResponse(
        revision: UInt64,
        lastSeenAt: String,
        identityGeneration: Int = 1,
        relayFleet: [String] = ["https://relay.example/"],
        capabilities: [String] = ["terminal"],
        grantVerificationKeyIDs: [String] = [],
        includesPeerBinding: Bool = true
    ) throws -> CmxConnectivitySyncResponse {
        let capabilityList = capabilities
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        let binding = """
            {
              "binding_id": "0a0a0a0a-0000-4000-8000-000000000001",
              "device_id": "\(peerDeviceID)",
              "app_instance_id": "0a0a0a0a-0000-4000-8000-000000000002",
              "tag": "default",
              "platform": "mac",
              "endpoint_id": "\(peerEndpointID)",
              "identity_generation": \(identityGeneration),
              "pairing_enabled": true,
              "capabilities": [\(capabilityList)],
              "path_hints": [],
              "last_seen_at": "\(lastSeenAt)"
            }
            """
        let fleet = relayFleet
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        let keys = grantVerificationKeyIDs
            .map {
                """
                {"kid": "\($0)", "alg": "ed25519", "spki_der_base64": "QUJD"}
                """
            }
            .joined(separator: ", ")
        return try decodeResponse(
            """
            {
              "protocol_version": 2,
              "revision": \(revision),
              "changed": true,
              "reset": false,
              "snapshot": {
                "route_contract_version": 1,
                "revision": \(revision),
                "bindings": [\(includesPeerBinding ? binding : "")],
                "relay_fleet": [\(fleet)],
                "lan_rendezvous": {
                  "generation": 1,
                  "key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                },
                "grant_verification_keys": {
                  "version": 1,
                  "current_kid": "current",
                  "keys": [\(keys)]
                }
              }
            }
            """
        )
    }

    private static func endpointConfiguration() throws -> CmxIrohEndpointConfiguration {
        CmxIrohEndpointConfiguration(
            secretKey: try CmxIrohSecretKey(bytes: Data(repeating: 5, count: 32)),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            relayProfile: .unavailableManagedSelection
        )
    }

    private static func changedResponse(
        revision: UInt64
    ) throws -> CmxConnectivitySyncResponse {
        try decodeResponse(
            """
            {
              "protocol_version": 2,
              "revision": \(revision),
              "changed": true,
              "reset": false,
              "snapshot": {
                "route_contract_version": 1,
                "revision": \(revision),
                "bindings": [],
                "relay_fleet": ["https://relay.example/"],
                "lan_rendezvous": {
                  "generation": 1,
                  "key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                },
                "grant_verification_keys": {
                  "version": 1,
                  "current_kid": "current",
                  "keys": []
                }
              }
            }
            """
        )
    }

    private static func unchangedResponse(
        revision: UInt64
    ) throws -> CmxConnectivitySyncResponse {
        try decodeResponse(
            """
            {
              "protocol_version": 2,
              "revision": \(revision),
              "changed": false,
              "reset": false
            }
            """
        )
    }

    private static func decodeResponse(
        _ json: String
    ) throws -> CmxConnectivitySyncResponse {
        try JSONDecoder().decode(
            CmxConnectivitySyncResponse.self,
            from: Data(json.utf8)
        )
    }

    private static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 2_000 {
            if await condition() { return }
            await Task.yield()
        }
        struct TimedOut: Error {}
        throw TimedOut()
    }
}

private actor ScriptedConnectivityAuthority: CmxConnectivityAuthorityServing {
    private var responses: [CmxConnectivitySyncResponse]
    private var observedKnownRevisions: [UInt64?] = []

    init(responses: [CmxConnectivitySyncResponse]) {
        self.responses = responses
    }

    func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        observedKnownRevisions.append(knownRevision)
        guard !responses.isEmpty else {
            throw CmxIrohTrustBrokerClientError.connectivity(nil)
        }
        return responses.removeFirst()
    }

    func knownRevisions() -> [UInt64?] { observedKnownRevisions }
}

private actor InitialThenFailingConnectivityAuthority: CmxConnectivityAuthorityServing {
    private let initial: CmxConnectivitySyncResponse
    private var calls = 0

    init(initial: CmxConnectivitySyncResponse) {
        self.initial = initial
    }

    func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        calls += 1
        if knownRevision == nil {
            return initial
        }
        throw CmxIrohTrustBrokerClientError.connectivity(nil)
    }

    func callCount() -> Int { calls }
}

private actor ConnectivityObservationFlag {
    private var finished = false

    func markFinished() {
        finished = true
    }

    func value() -> Bool { finished }
}

private actor GatedReplacementEndpointFactory: CmxIrohEndpointFactory {
    private let first: any CmxIrohEndpoint
    private let replacement: any CmxIrohEndpoint
    private var calls = 0
    private var replacementWaiter: CheckedContinuation<any CmxIrohEndpoint, Never>?

    init(
        first: any CmxIrohEndpoint,
        replacement: any CmxIrohEndpoint
    ) {
        self.first = first
        self.replacement = replacement
    }

    func bind(
        configuration _: CmxIrohEndpointConfiguration
    ) async -> any CmxIrohEndpoint {
        calls += 1
        if calls == 1 { return first }
        return await withCheckedContinuation { continuation in
            replacementWaiter = continuation
        }
    }

    func bindCallCount() -> Int { calls }

    func releaseReplacement() {
        replacementWaiter?.resume(returning: replacement)
        replacementWaiter = nil
    }
}

private actor GatedConnectivityAuthority: CmxConnectivityAuthorityServing {
    private let changed: CmxConnectivitySyncResponse
    private let unchanged: CmxConnectivitySyncResponse
    private var calls = 0
    private var firstRequestGate: CheckedContinuation<Void, Never>?

    init(
        changed: CmxConnectivitySyncResponse,
        unchanged: CmxConnectivitySyncResponse
    ) {
        self.changed = changed
        self.unchanged = unchanged
    }

    func syncConnectivity(
        knownRevision: UInt64?
    ) async -> CmxConnectivitySyncResponse {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation in
                firstRequestGate = continuation
            }
        }
        return knownRevision == nil ? changed : unchanged
    }

    func releaseFirstRequest() {
        firstRequestGate?.resume()
        firstRequestGate = nil
    }

    func callCount() -> Int { calls }
}

private actor ConnectivitySnapshotInstallerRecorder {
    private var installedRevisions: [UInt64] = []

    func install(_ snapshot: CmxIrohDiscoveryResponse) {
        if let revision = snapshot.revision {
            installedRevisions.append(revision)
        }
    }

    func revisions() -> [UInt64] { installedRevisions }
}

private struct FailingConnectivityContextProvider: CmxIrohClientContextProvider {
    func context(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIrohClientContext {
        _ = request
        throw CmxConnectivityEngineError.inactive
    }
}
