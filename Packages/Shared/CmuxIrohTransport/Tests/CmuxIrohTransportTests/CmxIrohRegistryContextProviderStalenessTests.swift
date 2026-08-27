import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Level-triggered discovery-freshness behavior (docs/transport-plane.md, D5):
/// a failed dial on an empty or unreachable plan, an empty plan before
/// dialing, and a presence route push must all force the next dial plan to be
/// rebuilt from a fresh broker snapshot, while healthy dials keep reusing the
/// verified-snapshot window and broker cooldowns are never spun against.
@Suite
struct CmxIrohRegistryContextProviderStalenessTests {
    @Test
    func dialFailureOnEmptyPlanForcesOneFreshDiscoveryAndRebuiltPlan() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        // The reusable verified snapshot advertises NO usable target paths:
        // the corpse state a relaunched Mac leaves behind.
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [])
        )
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try testIrohDialPlan(publicPaths: []),
            failure: .unknown
        )
        // The broker has since seen the Mac re-register with a live relay path.
        await broker.setDiscovery(try fixture.discovery(targetHints: [relay]))

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(await broker.discoveryRequestCount() == 1)
        #expect(context.dialPlan.publicPaths == [relay])
    }

    @Test
    func unreachableDialFailureBypassesVerifiedSnapshotReuse() async throws {
        let fixture = try RegistryFixture()
        let staleRelay = try managedRelayHint(fixture)
        let freshDirect = try publicDirectHint(fixture, value: "8.8.8.8:4433")
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [freshDirect]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [staleRelay])
        )
        // A non-empty plan whose dial timed out: the peer endpoint is stale.
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try nonEmptyPlan(fixture, hints: [staleRelay]),
            failure: .timedOut
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(await broker.discoveryRequestCount() == 1)
        #expect(context.dialPlan.publicPaths == [freshDirect])
    }

    @Test
    func authorizationFailuresDoNotInvalidateDiscoveryReuse() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [relay])
        )
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try nonEmptyPlan(fixture, hints: [relay]),
            failure: .admissionDenied
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        // The verified snapshot was reused: no broker fetch happened.
        #expect(await broker.discoveryRequestCount() == 0)
        #expect(context.dialPlan.publicPaths == [relay])
    }

    @Test
    func routeGatingDoesNotInvalidateDiscoveryReuse() async throws {
        let fixture = try RegistryFixture()
        let reusedRelay = try managedRelayHint(fixture)
        let brokerOnlyDirect = try publicDirectHint(
            fixture,
            value: "8.8.4.4:4433"
        )
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [brokerOnlyDirect]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [reusedRelay])
        )

        // A route-gated error means another caller already owns this route.
        // It carries no evidence that the broker's peer binding is stale.
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try nonEmptyPlan(fixture, hints: [reusedRelay]),
            failure: .routeGated
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(await broker.discoveryRequestCount() == 0)
        #expect(context.dialPlan.publicPaths == [reusedRelay])
    }

    @Test
    func sharedDiscoveryUsesRevisionedAuthorityAndRecordsRouteShape() async throws {
        let fixture = try RegistryFixture()
        let staleRelay = try managedRelayHint(fixture)
        let freshDirect = try publicDirectHint(fixture, value: "8.8.8.8:4433")
        let cached = try fixture.discovery(
            targetHints: [staleRelay],
            revision: 7
        )
        let fresh = try fixture.discovery(
            targetHints: [freshDirect],
            revision: 8
        )
        let broker = RevisionedRegistryBroker(
            syncResponse: CmxConnectivitySyncResponse(
                legacySnapshot: fresh,
                knownRevision: cached.revision
            ),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let diagnostics = DiagnosticLog(capacity: 8, role: .mobileClient)
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            diagnostics: diagnostics,
            verifiedDiscovery: cached
        )
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try nonEmptyPlan(fixture, hints: [staleRelay]),
            failure: .noRoute
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(context.dialPlan.publicPaths == [freshDirect])
        #expect(await broker.observedKnownRevisions() == [7])
        #expect(await broker.discoveryRequestCount() == 0)
        #expect(await waitForDiagnosticProcessedCount(diagnostics, atLeast: 2))
        let events = await diagnostics.snapshot().events
        #expect(events.map(\.code) == [.discoveryStarted, .discoverySucceeded])
        #expect(events[1].ms != nil)
        #expect(events[1].b == fresh.bindings.count)
        #expect(events[1].c == fresh.relayFleet.count)
    }

    @Test
    func normalDialsReuseVerifiedSnapshotOnceWithinWindow() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [relay])
        )

        let first = try await provider.context(for: fixture.request(hints: []))
        #expect(await broker.discoveryRequestCount() == 0)
        #expect(first.dialPlan.publicPaths == [relay])

        // The snapshot is one-shot: a healthy second dial fetches normally.
        let second = try await provider.context(for: fixture.request(hints: []))
        #expect(await broker.discoveryRequestCount() == 1)
        #expect(second.dialPlan.publicPaths == [relay])
    }

    @Test
    func emptyPlanFromReusedSnapshotRefetchesBeforeDialing() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [])
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        // The reused snapshot produced a no-relays/no-direct-addrs plan, so
        // the provider refetched once instead of returning a doomed dial.
        #expect(await broker.discoveryRequestCount() == 1)
        #expect(context.dialPlan.publicPaths == [relay])
    }

    @Test
    func emptyPlanFromFreshDiscoveryDoesNotRefetchAgain() async throws {
        let fixture = try RegistryFixture()
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: nil
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        // Fresh discovery is authoritative: an empty plan stays empty with
        // exactly one fetch, never a same-dial retry storm.
        #expect(await broker.discoveryRequestCount() == 1)
        #expect(context.dialPlan.publicPaths.isEmpty)
        #expect(context.dialPlan.privateFallbackPaths.isEmpty)
    }

    @Test
    func concurrentStaleDialsShareOneFreshDiscoveryFetch() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [
                try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                ),
                try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                ),
            ]
        )
        await broker.holdDiscoverCalls()
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: nil
        )
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try testIrohDialPlan(publicPaths: []),
            failure: .timedOut
        )

        let request = try fixture.request(hints: [])
        let firstDial = Task { try await provider.context(for: request) }
        let secondDial = Task { try await provider.context(for: request) }
        let reachedBroker = await waitForHeldDiscoverCalls(broker, atLeast: 1)
        #expect(reachedBroker)
        // Both dials are in flight; only one broker request may exist.
        for _ in 0 ..< 100 {
            await Task.yield()
            #expect(await broker.heldDiscoverCallCount() == 1)
        }
        await broker.releaseHeldDiscoverCalls()

        let first = try await firstDial.value
        let second = try await secondDial.value
        #expect(await broker.discoveryRequestCount() == 1)
        #expect(first.dialPlan.publicPaths == [relay])
        #expect(second.dialPlan.publicPaths == [relay])
    }

    @Test
    func presenceInvalidationBypassesReuseWindowForThatDevice() async throws {
        let fixture = try RegistryFixture()
        let staleRelay = try managedRelayHint(fixture)
        let freshDirect = try publicDirectHint(fixture, value: "8.8.4.4:4433")
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [freshDirect]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [staleRelay])
        )

        // A presence route push announced this Mac re-registered. The device
        // id arrives in registry (uppercase-tolerant) form.
        await provider.invalidateVerifiedDiscovery(
            forDeviceID: fixture.acceptor.deviceID.uppercased()
        )

        let context = try await provider.context(for: fixture.request(hints: []))
        #expect(await broker.discoveryRequestCount() == 1)
        #expect(context.dialPlan.publicPaths == [freshDirect])
    }

    @Test
    func brokerCooldownIsRespectedWithoutFetchStormAndStalenessSurvives() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: nil
        )
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try testIrohDialPlan(publicPaths: []),
            failure: .timedOut
        )
        await broker.setDiscoverError(
            CmxIrohTrustBrokerClientError.rateLimited(code: "slow_down", retryAfterSeconds: 30)
        )

        // The gate's directive propagates: the dial fails with the bounded
        // retry-after (the reconnect backoff owner waits it out) instead of
        // the provider retrying discovery inside one attempt.
        await #expect(throws: CmxIrohTrustBrokerClientError.rateLimited(
            code: "slow_down",
            retryAfterSeconds: 30
        )) {
            _ = try await provider.context(for: fixture.request(hints: []))
        }
        #expect(await broker.discoveryRequestCount() == 1)

        // After the floor lifts, the retained staleness still forces exactly
        // one fresh fetch and the plan rebuilds.
        await broker.setDiscoverError(nil)
        let context = try await provider.context(for: fixture.request(hints: []))
        #expect(await broker.discoveryRequestCount() == 2)
        #expect(context.dialPlan.publicPaths == [relay])
    }

    @Test
    func refreshFailureAfterStalenessFallsBackToLastVerifiedSnapshot() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [relay])
        )
        // A timed-out dial marked the peer stale, so the next attempt must
        // try one fresh fetch first.
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try nonEmptyPlan(fixture, hints: [relay]),
            failure: .timedOut
        )
        await broker.setDiscoverError(CmxIrohTrustBrokerClientError.connectivity)

        // The forced refresh failed. Dialing with the last verified snapshot
        // beats not dialing at all (cmux#9724): the staleness mark survives,
        // so a later attempt still refetches once the broker recovers.
        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(await broker.discoveryRequestCount() == 1)
        #expect(context.dialPlan.publicPaths == [relay])
    }

    @Test
    func cooldownDuringEmptyPlanRefetchKeepsResolvedContextInsteadOfSpinning() async throws {
        let fixture = try RegistryFixture()
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [])
        )
        await broker.setDiscoverError(
            CmxIrohBrokerCooldownError(retryAfterSeconds: 42)
        )

        // The reused snapshot yields an empty plan; the rescue refetch hits a
        // broker cooldown. Waiting means returning the buildable context (its
        // LAN fallback still applies), not failing or retrying the broker.
        let context = try await provider.context(for: fixture.request(hints: []))
        #expect(await broker.discoveryRequestCount() == 1)
        #expect(context.dialPlan.publicPaths.isEmpty)
    }

    @Test
    func nonTransientRefreshFailuresDoNotReuseLastGoodDiscovery() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        let grant = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [grant, grant, grant]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [relay])
        )
        // A healthy dial consumes the one-shot verified snapshot, leaving the
        // last-good authoritative snapshot armed for the next refresh.
        _ = try await provider.context(for: fixture.request(hints: []))
        #expect(await broker.discoveryRequestCount() == 0)

        // Rollback/equivocation detection surfaces as `invalidResponse`; a
        // revoked or replaced binding as a non-transient rejection. Neither
        // may be masked by silently dialing with the last verified snapshot:
        // both must fail closed toward re-discovery.
        for error in [
            CmxIrohTrustBrokerClientError.invalidResponse,
            CmxIrohTrustBrokerClientError.rejected(
                statusCode: 403,
                code: "binding_revoked"
            ),
        ] {
            await broker.setDiscoverError(error)
            await #expect(throws: error) {
                try await provider.context(for: fixture.request(hints: []))
            }
        }
    }

    @Test
    func connectivityRefreshFailuresStillReuseLastGoodDiscovery() async throws {
        let fixture = try RegistryFixture()
        let relay = try managedRelayHint(fixture)
        let grant = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [grant, grant]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            verifiedDiscovery: try fixture.discovery(targetHints: [relay])
        )
        _ = try await provider.context(for: fixture.request(hints: []))
        #expect(await broker.discoveryRequestCount() == 0)

        // The transient class keeps the cmux#9724 behavior: dialing with the
        // last verified snapshot beats not dialing at all while the broker
        // recovers.
        await broker.setDiscoverError(CmxIrohTrustBrokerClientError.connectivity)
        let context = try await provider.context(for: fixture.request(hints: []))
        #expect(context.dialPlan.publicPaths == [relay])
    }

    // MARK: - Support

    private func makeProvider(
        fixture: RegistryFixture,
        broker: any CmxIrohRegistryServing,
        diagnostics: DiagnosticLog? = nil,
        verifiedDiscovery: CmxIrohDiscoveryResponse?
    ) async throws -> CmxIrohRegistryContextProvider {
        CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(
                    generation: 1,
                    activeNetworkProfiles: []
                )
            },
            diagnostics: diagnostics,
            verifiedDiscovery: verifiedDiscovery,
            now: { fixture.now }
        )
    }

    private func managedRelayHint(
        _ fixture: RegistryFixture
    ) throws -> CmxIrohPathHint {
        // Broker bindings only carry hints with a bounded observation window.
        try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60)
        )
    }

    private func publicDirectHint(
        _ fixture: RegistryFixture,
        value: String
    ) throws -> CmxIrohPathHint {
        try CmxIrohPathHint(
            kind: .directAddress,
            value: value,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60)
        )
    }

    /// A dial plan carrying `hints` as usable public paths at the fixture's
    /// frozen clock (the shared `testIrohDialPlan` helper evaluates usability
    /// at the real wall clock, which sits before the fixture epoch).
    private func nonEmptyPlan(
        _ fixture: RegistryFixture,
        hints: [CmxIrohPathHint]
    ) throws -> CmxIrohDialPlan {
        let plan = CmxAttachEndpoint.peer(
            identity: fixture.acceptor.endpointID,
            pathHints: hints
        ).irohDialPlan(
            at: fixture.now,
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: []
        )
        guard let plan, !plan.publicPaths.isEmpty else {
            throw TestRegistryError.noGrantResponse
        }
        return plan
    }

    private func waitForHeldDiscoverCalls(
        _ broker: ConfigurableRegistryBroker,
        atLeast count: Int
    ) async -> Bool {
        for _ in 0 ..< 2_000 {
            if await broker.heldDiscoverCallCount() >= count { return true }
            await Task.yield()
        }
        return await broker.heldDiscoverCallCount() >= count
    }
}

/// A broker that exposes the connectivity-v2 authority seam. `discover()` is
/// deliberately observable so the test proves the registry provider does not
/// bypass revision reconciliation during a stale-route refresh.
actor RevisionedRegistryBroker: CmxIrohRegistryServing,
    CmxConnectivityAuthorityServing {
    private let syncResponse: CmxConnectivitySyncResponse
    private var pairGrantResponses: [CmxIrohPairGrantResponse]
    private var knownRevisions: [UInt64?] = []
    private var discoverCalls = 0

    init(
        syncResponse: CmxConnectivitySyncResponse,
        pairGrantResponses: [CmxIrohPairGrantResponse]
    ) {
        self.syncResponse = syncResponse
        self.pairGrantResponses = pairGrantResponses
    }

    func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        knownRevisions.append(knownRevision)
        return syncResponse
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        discoverCalls += 1
        throw TestIrohTransportError.unsupported
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        guard !pairGrantResponses.isEmpty else {
            throw TestRegistryError.noGrantResponse
        }
        return pairGrantResponses.removeFirst()
    }

    func observedKnownRevisions() -> [UInt64?] { knownRevisions }

    func discoveryRequestCount() -> Int { discoverCalls }
}

/// A registry broker whose discovery response, failure mode, and completion
/// timing are all adjustable mid-test, so staleness tests can model a Mac
/// re-registering, a broker cooldown, and concurrent held requests.
actor ConfigurableRegistryBroker: CmxIrohRegistryServing {
    private var discoveryResponse: CmxIrohDiscoveryResponse
    private var pairGrantResponses: [CmxIrohPairGrantResponse]
    private var discoverError: (any Error)?
    private var completedDiscoverCalls = 0
    private var completedPairGrantCalls = 0
    private var holdDiscover = false
    private var heldDiscoverContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        discovery: CmxIrohDiscoveryResponse,
        pairGrantResponses: [CmxIrohPairGrantResponse]
    ) {
        discoveryResponse = discovery
        self.pairGrantResponses = pairGrantResponses
    }

    func discover() async throws -> CmxIrohDiscoveryResponse {
        if holdDiscover {
            await withCheckedContinuation { continuation in
                heldDiscoverContinuations.append(continuation)
            }
        }
        completedDiscoverCalls += 1
        if let discoverError { throw discoverError }
        return discoveryResponse
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        completedPairGrantCalls += 1
        guard !pairGrantResponses.isEmpty else {
            throw TestRegistryError.noGrantResponse
        }
        return pairGrantResponses.removeFirst()
    }

    func pairGrantRequestCount() -> Int {
        completedPairGrantCalls
    }

    func setDiscovery(_ discovery: CmxIrohDiscoveryResponse) {
        discoveryResponse = discovery
    }

    func setDiscoverError(_ error: (any Error)?) {
        discoverError = error
    }

    func holdDiscoverCalls() {
        holdDiscover = true
    }

    func releaseHeldDiscoverCalls() {
        holdDiscover = false
        let continuations = heldDiscoverContinuations
        heldDiscoverContinuations = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func heldDiscoverCallCount() -> Int {
        heldDiscoverContinuations.count
    }

    func discoveryRequestCount() -> Int {
        completedDiscoverCalls
    }
}
