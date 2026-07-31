import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

struct CmxConnectivityEngineTests {
    @Test
    func exactForegroundNoPathIsNotMaskedByHealthyBackgroundPeer() throws {
        let foregroundRequest = try Self.request(
            endpointByte: "a",
            deviceID: "123e4567-e89b-42d3-a456-426614174100"
        )
        let backgroundRequest = try Self.request(
            endpointByte: "b",
            deviceID: "123e4567-e89b-42d3-a456-426614174200"
        )
        let foregroundID = try CmxConnectivityPeerID(request: foregroundRequest)
        let backgroundID = try CmxConnectivityPeerID(request: backgroundRequest)
        let snapshots = [
            foregroundID: Self.peerSnapshot(
                peerID: foregroundID,
                phase: .connected
            ),
            backgroundID: Self.peerSnapshot(
                peerID: backgroundID,
                phase: .connected
            ),
        ]
        let observedPaths: [CmxConnectivityPeerID: CmxIrohObservedConnectionPath] = [
            foregroundID: .unavailable,
            backgroundID: .direct,
        ]

        #expect(
            CmxIrohSelectedPathHealthClassifier().classify(
                request: foregroundRequest,
                snapshots: snapshots,
                observedPaths: observedPaths
            ) == .noPath
        )
        #expect(
            CmxIrohSelectedPathHealthClassifier().classify(
                request: backgroundRequest,
                snapshots: snapshots,
                observedPaths: observedPaths
            ) == .healthy
        )
    }

    @Test
    func missingOrTransitioningExactPeerPathIsUnknown() throws {
        let request = try Self.request(
            endpointByte: "c",
            deviceID: "123e4567-e89b-42d3-a456-426614174300"
        )
        let peerID = try CmxConnectivityPeerID(request: request)
        let classifier = CmxIrohSelectedPathHealthClassifier()

        #expect(
            classifier.classify(
                request: request,
                snapshots: [:],
                observedPaths: [:]
            ) == .unknown
        )
        #expect(
            classifier.classify(
                request: request,
                snapshots: [
                    peerID: Self.peerSnapshot(
                        peerID: peerID,
                        phase: .connecting
                    ),
                ],
                observedPaths: [:]
            ) == .unknown
        )
    }

    @Test
    func validCachedRevisionBecomesActiveBeforeAuthorityRefreshCompletes() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
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
        await engine.didInstallRouteRevision(8)

        try await engine.start()
        try await Self.waitUntil { await authority.callCount() == 1 }

        let cached = await engine.snapshot()
        #expect(cached.phase == .active)
        #expect(cached.endpointGeneration == 1)
        #expect(cached.localIdentity == identity)
        #expect(cached.routeRevision == 8)
        #expect(await installer.revisions().isEmpty)

        await authority.releaseFirstRequest()
        try await Self.waitUntil {
            await engine.snapshot().routeRevision == 9
        }
        #expect(await installer.revisions() == [9])
        await engine.stop()
    }

    @Test
    func startWithoutCachedRevisionInstallsAuthorityBeforeBecomingActive() async throws {
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
    func connectivityFailurePreservesCachedReadinessDuringBackgroundReconciliation() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "d", count: 64)
        )
        let authority = FailingConnectivityAuthority(error: .connectivity)
        let engine = CmxConnectivityEngine(
            supervisor: CmxIrohEndpointSupervisor(
                factory: TestIrohEndpointFactory(
                    endpoints: [TestIrohEndpoint(identity: identity)]
                ),
                configuration: try Self.endpointConfiguration()
            ),
            contextProvider: FailingConnectivityContextProvider(),
            authority: authority,
            installRouteSnapshot: { _ in }
        )
        await engine.didInstallRouteRevision(4)

        try await engine.start()
        try await Self.waitUntil { await authority.callCount() == 1 }
        for _ in 0 ..< 100 { await Task.yield() }

        #expect(await engine.snapshot().phase == .active)
        #expect(await engine.snapshot().routeRevision == 4)
        await engine.stop()
    }

    @Test
    func terminalAuthorityFailureRevokesCachedReadiness() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "e", count: 64)
        )
        let authority = FailingConnectivityAuthority(error: .invalidResponse)
        let engine = CmxConnectivityEngine(
            supervisor: CmxIrohEndpointSupervisor(
                factory: TestIrohEndpointFactory(
                    endpoints: [TestIrohEndpoint(identity: identity)]
                ),
                configuration: try Self.endpointConfiguration()
            ),
            contextProvider: FailingConnectivityContextProvider(),
            authority: authority,
            installRouteSnapshot: { _ in }
        )
        await engine.didInstallRouteRevision(4)

        try await engine.start()
        try await Self.waitUntil {
            await engine.snapshot().phase == .failed
        }

        #expect(await authority.callCount() == 1)
        await engine.stop()
    }

    @Test
    func mismatchedUnchangedRevisionCannotAdvanceCachedAuthority() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "f", count: 64)
        )
        let engine = CmxConnectivityEngine(
            supervisor: CmxIrohEndpointSupervisor(
                factory: TestIrohEndpointFactory(
                    endpoints: [TestIrohEndpoint(identity: identity)]
                ),
                configuration: try Self.endpointConfiguration()
            ),
            contextProvider: FailingConnectivityContextProvider(),
            authority: StaticConnectivityAuthority(
                response: try Self.unchangedResponse(revision: 9)
            ),
            installRouteSnapshot: { _ in }
        )
        await engine.didInstallRouteRevision(8)

        try await engine.start()
        try await Self.waitUntil {
            await engine.snapshot().phase == .failed
        }

        #expect(await engine.snapshot().routeRevision == 8)
        await engine.stop()
    }

    @Test
    func routeAuthorityDiffPreservesPathChangesAndInvalidatesRevocationOrSubstitution()
        throws
    {
        let fixture = try ClientRuntimeTestFixture()
        let peerID = CmxConnectivityPeerID(
            identity: fixture.binding.endpointID,
            deviceID: fixture.binding.deviceID
        )
        let initial = try CmxConnectivityRouteAuthorityIndex(
            discovery: fixture.discovery
        )
        let revisionOnly = try CmxConnectivityRouteAuthorityIndex(
            discovery: CmxIrohDiscoveryResponse(
                routeContractVersion: fixture.discovery.routeContractVersion,
                revision: 2,
                bindings: fixture.discovery.bindings,
                relayFleet: fixture.discovery.relayFleet,
                lanRendezvous: fixture.discovery.lanRendezvous,
                grantVerificationKeys: fixture.discovery.grantVerificationKeys
            )
        )
        let pathBinding = try Self.bindingWithDifferentPath(fixture.binding)
        let pathOnly = try CmxConnectivityRouteAuthorityIndex(
            discovery: CmxIrohDiscoveryResponse(
                routeContractVersion: fixture.discovery.routeContractVersion,
                revision: 3,
                bindings: [pathBinding],
                relayFleet: fixture.discovery.relayFleet,
                lanRendezvous: fixture.discovery.lanRendezvous,
                grantVerificationKeys: fixture.discovery.grantVerificationKeys
            )
        )
        let substitutedBinding = try ClientRuntimeTestFixture.binding(
            endpointID: fixture.binding.endpointID.endpointID,
            bindingID: "223e4567-e89b-42d3-a456-426614174020",
            deviceID: fixture.binding.deviceID,
            appInstanceID: fixture.binding.appInstanceID
        )
        let substituted = try CmxConnectivityRouteAuthorityIndex(
            discovery: try ClientRuntimeTestFixture.discovery(
                binding: substitutedBinding,
                revision: 4
            )
        )
        let revoked = try CmxConnectivityRouteAuthorityIndex(
            discovery: try ClientRuntimeTestFixture.discovery(
                binding: fixture.binding,
                includeBinding: false,
                revision: 5
            )
        )

        #expect(
            revisionOnly.invalidatedPeers(
                replacing: initial,
                activePeers: [peerID]
            ).isEmpty
        )
        #expect(
            pathOnly.invalidatedPeers(
                replacing: initial,
                activePeers: [peerID]
            ).isEmpty
        )
        #expect(
            substituted.invalidatedPeers(
                replacing: initial,
                activePeers: [peerID]
            ) == [peerID]
        )
        #expect(
            revoked.invalidatedPeers(
                replacing: initial,
                activePeers: [peerID]
            ) == [peerID]
        )
    }

    @Test
    func duplicatePeerAuthorityFailsClosedInsteadOfTrapping() throws {
        let fixture = try ClientRuntimeTestFixture()
        let duplicate = try ClientRuntimeTestFixture.binding(
            endpointID: fixture.binding.endpointID.endpointID,
            bindingID: "323e4567-e89b-42d3-a456-426614174020",
            deviceID: fixture.binding.deviceID,
            appInstanceID: "323e4567-e89b-42d3-a456-426614174022"
        )
        let discovery = CmxIrohDiscoveryResponse(
            routeContractVersion: fixture.discovery.routeContractVersion,
            revision: 2,
            bindings: [fixture.binding, duplicate],
            relayFleet: fixture.discovery.relayFleet,
            lanRendezvous: fixture.discovery.lanRendezvous,
            grantVerificationKeys: fixture.discovery.grantVerificationKeys
        )

        #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            try CmxConnectivityRouteAuthorityIndex(discovery: discovery)
        }
    }

    private static func endpointConfiguration() throws -> CmxIrohEndpointConfiguration {
        CmxIrohEndpointConfiguration(
            secretKey: try CmxIrohSecretKey(bytes: Data(repeating: 5, count: 32)),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            relayProfile: .unavailableManagedSelection
        )
    }

    private static func request(
        endpointByte: Character,
        deviceID: String
    ) throws -> CmxByteTransportRequest {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: endpointByte, count: 64)
        )
        return CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh-\(endpointByte)",
                kind: .iroh,
                endpoint: .peer(identity: identity, pathHints: [])
            ),
            expectedPeerDeviceID: deviceID,
            authorizationMode: .transportAdmission
        )
    }

    private static func peerSnapshot(
        peerID: CmxConnectivityPeerID,
        phase: CmxConnectivityPeerSnapshot.Phase
    ) -> CmxConnectivityPeerSnapshot {
        CmxConnectivityPeerSnapshot(
            peerID: peerID,
            phase: phase,
            connectionGeneration: 1,
            stateRevision: 1,
            failure: .none,
            controlLaneOwned: false
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

    private static func bindingWithDifferentPath(
        _ binding: CmxIrohBrokerBinding
    ) throws -> CmxIrohBrokerBinding {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(binding)
            ) as? [String: Any]
        )
        let observedAt = Date(timeIntervalSince1970: 1_783_686_000)
        let hint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example/",
            source: .native,
            privacyScope: .publicInternet,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(600)
        )
        object["path_hints"] = [
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(hint)
            ),
        ]
        object["last_seen_at"] = "2026-07-10T12:05:00.000Z"
        return try JSONDecoder().decode(
            CmxIrohBrokerBinding.self,
            from: JSONSerialization.data(withJSONObject: object)
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

private actor FailingConnectivityAuthority: CmxConnectivityAuthorityServing {
    private let error: CmxIrohTrustBrokerClientError
    private var calls = 0

    init(error: CmxIrohTrustBrokerClientError) {
        self.error = error
    }

    func syncConnectivity(
        knownRevision _: UInt64?
    ) throws -> CmxConnectivitySyncResponse {
        calls += 1
        throw error
    }

    func callCount() -> Int { calls }
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
        return knownRevision == changed.revision ? unchanged : changed
    }

    func releaseFirstRequest() {
        firstRequestGate?.resume()
        firstRequestGate = nil
    }

    func callCount() -> Int { calls }
}

private actor StaticConnectivityAuthority: CmxConnectivityAuthorityServing {
    private let response: CmxConnectivitySyncResponse

    init(response: CmxConnectivitySyncResponse) {
        self.response = response
    }

    func syncConnectivity(
        knownRevision _: UInt64?
    ) -> CmxConnectivitySyncResponse {
        response
    }
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
