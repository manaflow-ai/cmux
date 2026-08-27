import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Warm-client cache-first activation: a client holding a verified cached
/// binding AND a verified offline route record activates with ZERO blocking
/// broker rounds. The authenticated registration refresh runs immediately
/// behind activation and fails closed on a non-transient rejection, mirroring
/// the Mac host's cache-first activation (cmux#10737).
@Suite
struct CmxIrohClientRuntimeCacheFirstTests {
    /// The broker is completely hung (discovery sync and registration both
    /// block forever). A warm client must still reach `.active` from its
    /// verified caches and install the cached target routes.
    @Test
    func warmStartActivatesFromVerifiedCacheWhileBrokerIsHung() async throws {
        let seed = try await CacheFirstRuntimeSeed()
        let broker = TestRevisionedClientBroker(
            binding: seed.localBinding,
            discoveries: [
                try seed.fixture.discovery(targetHints: [], revision: 1),
                try seed.fixture.discovery(targetHints: [], revision: 1),
            ],
            blockedSyncCount: 1,
            blockedRegistrationCount: 1,
            registrationRevision: 1
        )
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: seed.fixture.initiator.endpointID),
            ]),
            broker: broker,
            configuration: seed.configuration,
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: TestSecureCredentialStore()
            ),
            offlinePolicyCache: seed.cache,
            now: { seed.fixture.now },
            handleCachedBindings: { bindings, _ in
                await recorder.recordCachedBindings(bindings)
            }
        )

        let start = Task { try await runtime.start() }
        var activatedWhileBrokerHung = false
        for _ in 0 ..< 50_000 {
            if await runtime.snapshot().state == .active {
                activatedWhileBrokerHung = true
                break
            }
            await Task.yield()
        }
        #expect(activatedWhileBrokerHung)
        #expect(
            await recorder.observedCachedBindingDeviceIDs()
                == [[seed.fixture.acceptor.deviceID]]
        )

        await broker.releaseBlockedSync()
        await broker.releaseBlockedRegistration()
        try? await start.value
        // The immediate background refresh re-authenticates the cached
        // binding once the broker recovers.
        await broker.waitUntilRegistrationCount(1)
        for _ in 0 ..< 50_000 {
            if await runtime.liveDiscoverySnapshotGeneration() >= 1 { break }
            await Task.yield()
        }
        #expect(await runtime.liveDiscoverySnapshotGeneration() >= 1)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    /// #10737 semantics: cache-first activation succeeds, then the immediate
    /// authenticated refresh is rejected non-transiently (403). The runtime
    /// must tear down, invalidate persisted policy, and wipe the offline
    /// route cache instead of staying up on withdrawn authority.
    @Test
    func cacheFirstActivationFailsClosedWhenImmediateRefreshIsRejected() async throws {
        let seed = try await CacheFirstRuntimeSeed()
        let broker = TestRevisionedClientBroker(
            binding: seed.localBinding,
            discoveries: [],
            registrationError: .rejected(statusCode: 403, code: "binding_revoked")
        )
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: seed.fixture.initiator.endpointID),
            ]),
            broker: broker,
            configuration: seed.configuration,
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: TestSecureCredentialStore()
            ),
            offlinePolicyCache: seed.cache,
            now: { seed.fixture.now },
            handlePolicyInvalidation: {
                await recorder.recordPolicyInvalidation()
            }
        )

        try await runtime.start()
        #expect(await runtime.snapshot().state == .active)

        await broker.waitUntilRegistrationCount(1)
        var failedClosed = false
        for _ in 0 ..< 50_000 {
            if await runtime.snapshot().state == .failed {
                failedClosed = true
                break
            }
            await Task.yield()
        }
        #expect(failedClosed)
        #expect(await recorder.observedPolicyInvalidationCount() == 1)
        #expect(await seed.store.recordCount() == 0)
    }

    /// Transient refresh failures preserve the cache-first activation: a
    /// connectivity-failing broker cannot tear down verified local state.
    @Test
    func cacheFirstActivationSurvivesConnectivityOnlyRefreshFailures() async throws {
        let seed = try await CacheFirstRuntimeSeed()
        let broker = TestRevisionedClientBroker(
            binding: seed.localBinding,
            discoveries: [],
            registrationError: .connectivity
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: seed.fixture.initiator.endpointID),
            ]),
            broker: broker,
            configuration: seed.configuration,
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: TestSecureCredentialStore()
            ),
            offlinePolicyCache: seed.cache,
            now: { seed.fixture.now }
        )

        try await runtime.start()
        #expect(await runtime.snapshot().state == .active)

        await broker.waitUntilRegistrationCount(1)
        // Give the failed refresh a chance to (incorrectly) tear down.
        for _ in 0 ..< 2_000 {
            await Task.yield()
        }
        #expect(await runtime.snapshot().state == .active)
        #expect(await seed.store.recordCount() == 1)
        await runtime.stop()
    }

    /// A cached broker binding WITHOUT a verified offline route record keeps
    /// today's ordering: activation waits for the overlapped discovery sync.
    @Test
    func cachedBindingWithoutOfflineRecordStillRequiresLiveDiscovery() async throws {
        let seed = try await CacheFirstRuntimeSeed(seedOfflineRecord: false)
        let broker = TestRevisionedClientBroker(
            binding: seed.localBinding,
            discoveries: [
                try seed.fixture.discovery(targetHints: [], revision: 1),
                try seed.fixture.discovery(targetHints: [], revision: 1),
            ],
            blockedSyncCount: 1,
            registrationRevision: 1
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: seed.fixture.initiator.endpointID),
            ]),
            broker: broker,
            configuration: seed.configuration,
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: TestSecureCredentialStore()
            ),
            offlinePolicyCache: seed.cache,
            now: { seed.fixture.now }
        )

        let start = Task { try await runtime.start() }
        await broker.waitUntilSyncCount(1)
        for _ in 0 ..< 2_000 {
            await Task.yield()
        }
        // The discovery sync is still hung, so activation must not complete.
        #expect(await runtime.snapshot().state == .starting)

        await broker.releaseBlockedSync()
        try await start.value
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }
}

/// A warm client's persisted state: a broker binding metadata cache plus a
/// signed offline route record whose pair grant verifies against the stored
/// key set.
struct CacheFirstRuntimeSeed {
    let fixture: RegistryFixture
    let localBinding: CmxIrohBrokerBinding
    let targetBinding: CmxIrohBrokerBinding
    let store: TestSecureCredentialStore
    let cache: CmxIrohClientOfflinePolicyCache
    let configuration: CmxIrohClientRuntimeConfiguration

    init(seedOfflineRecord: Bool = true) async throws {
        fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [], revision: 1)
        localBinding = discovery.bindings[0]
        targetBinding = discovery.bindings[1]
        store = TestSecureCredentialStore()
        cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        if seedOfflineRecord {
            try await cache.save(
                localBinding: localBinding,
                targetBinding: targetBinding,
                discovery: discovery,
                pairGrant: fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 3_600
                ),
                for: fixture.offlineExpectation(),
                now: fixture.now
            )
        }
        let identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: fixture.privateKey.rawRepresentation),
            generation: fixture.initiator.identityGeneration
        )
        configuration = CmxIrohClientRuntimeConfiguration(
            accountID: "account-a",
            deviceID: fixture.initiator.deviceID,
            appInstanceID: localBinding.appInstanceID,
            clientNamespace: localBinding.clientNamespace,
            tag: fixture.initiator.tag,
            displayName: nil,
            identity: identity,
            capabilities: localBinding.capabilities,
            managedRelayURLs: [fixture.relayURL],
            cachedBinding: CmxIrohBrokerBindingMetadata(binding: localBinding)
        )
    }
}
