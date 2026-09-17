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
        throw CmxIrohTrustBrokerClientError.connectivity
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
