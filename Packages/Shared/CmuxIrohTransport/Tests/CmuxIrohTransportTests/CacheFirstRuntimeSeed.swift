import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

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
