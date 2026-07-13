import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohRelayPolicyServiceTests {
    @Test
    func staleManagedSelectionNarrowsWithoutWideningToAutomatic() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let stores = makeStores()
        let service = stores.service
        let response = try CmxIrohRelayPolicyResponse(
            policy: fixture.token(sequence: 1),
            preference: .managed(["cmux-us", "removed-relay"]),
            preferenceRevision: 1
        )

        let effective = try await service.install(
            response: response,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        #expect(effective.effectivePreference == .managed(["cmux-us"]))
        #expect(effective.staleRelayIDs == ["removed-relay"])
        #expect(effective.endpointRelayProfile.allowedRelayURLs == [fixture.relayURLs[0]])
        #expect(effective.managedSnapshot?.relays.map(\.id) == ["cmux-us"])
        let stored = try #require(
            try await stores.preferenceStore.load(accountID: "account-a")
        )
        #expect(stored.effective == .managed(["cmux-us"]))
        #expect(stored.staleRelayIDs == ["removed-relay"])

        let fullyStale = try CmxIrohRelayPolicyResponse(
            policy: fixture.token(sequence: 2),
            preference: .managed(["removed-relay"]),
            preferenceRevision: 2
        )
        let directOnly = try await service.install(
            response: fullyStale,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )
        #expect(directOnly.source == .managedUnavailable)
        #expect(directOnly.effectivePreference == nil)
        #expect(directOnly.endpointRelayProfile.allowedRelayURLs.isEmpty)
        #expect(await service.diagnosticsSnapshot().failure == .staleManagedSelection)
    }

    @Test
    func customStaticTokensStayDeviceLocalAndMissingTokenFailsClosed() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let stores = makeStores()
        let definition = try CmxIrohCustomRelayDefinition(
            id: "private-home",
            url: "https://relay.example.net:8443/",
            provider: "personal",
            region: "home",
            displayName: "Home relay",
            authMode: .staticToken
        )
        let response = try CmxIrohRelayPolicyResponse(
            policy: fixture.token(sequence: 1),
            preference: .custom([definition]),
            preferenceRevision: 1
        )

        let missing = try await stores.service.install(
            response: response,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )
        #expect(missing.source == .customUnavailable)
        #expect(missing.endpointRelayProfile.allowedRelayURLs.isEmpty)
        #expect(missing.missingCredentialRelayIDs == ["private-home"])

        let active = try await stores.service.setStaticCredential(
            "private-secret-token",
            relayID: "private-home",
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )
        #expect(active.source == .custom)
        #expect(active.endpointRelayProfile.allowedRelayURLs == [definition.url])
        #expect(active.endpointRelayProfile.activeRelays.first?.authenticationToken
            == "private-secret-token")
        let diagnostic = await stores.service.diagnosticsSnapshot()
        #expect(diagnostic.selectedRelayURLs == [definition.url])
        #expect(String(describing: diagnostic).contains("private-secret-token") == false)
    }

    @Test
    func unavailableCustomCredentialStorageFailsClosed() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let preferenceStore = CmxIrohRelayPreferenceStore(secureStore: TestSecureCredentialStore())
        let service = CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: preferenceStore,
            credentialStore: CmxIrohCustomRelayCredentialStore(
                secureStore: RelayPolicyServiceUnavailableSecureStore()
            )
        )
        let definition = try CmxIrohCustomRelayDefinition(
            id: "private-home",
            url: "https://relay.example.net/",
            provider: "personal",
            region: "home",
            authMode: .none
        )

        let effective = try await service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: .custom([definition]),
                preferenceRevision: 1
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: nil,
            now: fixture.now
        )

        #expect(effective.source == .customUnavailable)
        #expect(effective.endpointRelayProfile.allowedRelayURLs.isEmpty)
        #expect(await service.diagnosticsSnapshot().failure == .customCredentialUnavailable)
    }

    @Test
    func rollbackKeepsCurrentEffectivePolicyAndReportsFailure() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let service = makeStores().service
        let first = try await service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 7),
                preference: .automatic,
                preferenceRevision: 1
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        await #expect(throws: CmxIrohRelayPolicyError.rollback) {
            try await service.install(
                response: CmxIrohRelayPolicyResponse(
                    policy: fixture.token(sequence: 6),
                    preference: .automatic,
                    preferenceRevision: 2
                ),
                accountID: "account-a",
                trustRoot: fixture.firstTrustRoot,
                relayCredential: fixture.relayCredential(),
                now: fixture.now
            )
        }

        #expect(await service.effectivePolicy() == first)
        #expect(await service.diagnosticsSnapshot().policySequence == 7)
        #expect(await service.diagnosticsSnapshot().failure == .policyRollback)
    }

    @Test
    func preferenceRollbackIsRejectedBeforeNewPolicyCanAdvanceCache() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let stores = makeStores()
        _ = try await stores.service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 7),
                preference: .automatic,
                preferenceRevision: 2
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        await #expect(throws: CmxIrohRelayPolicyServiceError.preferenceRollback) {
            try await stores.service.install(
                response: CmxIrohRelayPolicyResponse(
                    policy: fixture.token(sequence: 8),
                    preference: .managed(["cmux-us"]),
                    preferenceRevision: 1
                ),
                accountID: "account-a",
                trustRoot: fixture.firstTrustRoot,
                relayCredential: fixture.relayCredential(),
                now: fixture.now
            )
        }
        let cached = try await stores.policyCache.load(
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )
        #expect(cached?.sequence == 7)
        #expect(await stores.service.diagnosticsSnapshot().failure == .preferenceRollback)
    }

    @Test
    func cacheRestoresUntilSignedExpiryAndSupportsStagedKeyRotation() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let stores = makeStores()
        _ = try await stores.service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: .automatic,
                preferenceRevision: 1
            ),
            accountID: "account-a",
            trustRoot: fixture.rotatedTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )
        _ = try await stores.service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 2, signer: 2),
                preference: .automatic,
                preferenceRevision: 2
            ),
            accountID: "account-a",
            trustRoot: fixture.rotatedTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        let restored = await stores.service.restore(
            accountID: "account-a",
            trustRoot: try fixture.secondTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )
        #expect(restored.usedCachedPolicy)
        #expect(restored.managedSnapshot?.policy.sequence == 2)

        let expired = await stores.service.restore(
            accountID: "account-a",
            trustRoot: try fixture.secondTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now.addingTimeInterval(3_600)
        )
        #expect(expired.source == .managedUnavailable)
        #expect(expired.endpointRelayProfile.allowedRelayURLs.isEmpty)
        #expect(await stores.service.diagnosticsSnapshot().failure == .policyExpired)
    }

    @Test
    func implicitRevisionZeroStillRejectsEquivocation() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let stores = makeStores()
        _ = try await stores.service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: .automatic,
                preferenceRevision: 0
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        await #expect(throws: CmxIrohRelayPolicyServiceError.preferenceRollback) {
            try await stores.service.install(
                response: CmxIrohRelayPolicyResponse(
                    policy: fixture.token(sequence: 2),
                    preference: .managed(["cmux-us"]),
                    preferenceRevision: 0
                ),
                accountID: "account-a",
                trustRoot: fixture.firstTrustRoot,
                relayCredential: fixture.relayCredential(),
                now: fixture.now
            )
        }
        let cached = try await stores.policyCache.load(
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )
        #expect(cached?.sequence == 1)
    }

    private func makeStores() -> (
        service: CmxIrohRelayPolicyService,
        policyCache: CmxIrohRelayPolicyCache,
        preferenceStore: CmxIrohRelayPreferenceStore
    ) {
        let policyCache = CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore())
        let preferenceStore = CmxIrohRelayPreferenceStore(secureStore: TestSecureCredentialStore())
        return (
            CmxIrohRelayPolicyService(
                policyCache: policyCache,
                preferenceStore: preferenceStore,
                credentialStore: CmxIrohCustomRelayCredentialStore(
                    secureStore: TestSecureCredentialStore()
                )
            ),
            policyCache,
            preferenceStore
        )
    }
}

private struct RelayPolicyServiceUnavailableSecureStore: CmxIrohSecureCredentialStoring {
    private struct Unavailable: Error {}

    func read(account: String) async throws -> Data? { throw Unavailable() }
    func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) async throws { throw Unavailable() }
    func delete(account: String) async throws { throw Unavailable() }
    func deleteAll() async throws { throw Unavailable() }
}
