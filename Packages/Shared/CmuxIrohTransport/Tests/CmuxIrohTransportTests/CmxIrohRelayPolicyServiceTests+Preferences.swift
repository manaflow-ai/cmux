import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohRelayPolicyServiceTests {
    @Test
    func accountMetadataAndDeviceCredentialsStaySeparatedByAccountAndURL() async throws {
        let secureStore = TestSecureCredentialStore()
        let credentialStore = CmxIrohCustomRelayCredentialStore(secureStore: secureStore)
        let relay = try CmxIrohCustomRelayDefinition(
            id: "private-home",
            url: "https://relay.example.net/",
            provider: "personal",
            region: "home",
            authMode: .staticToken
        )
        let configuration = try CmxIrohAccountRelayConfiguration.custom([relay])
        let token = "device-only-token"

        try await credentialStore.setStaticToken(
            token,
            relayID: relay.id,
            relayURL: relay.url,
            accountID: "account-a"
        )

        let accountMetadata = try JSONEncoder().encode(configuration)
        #expect(String(decoding: accountMetadata, as: UTF8.self).contains(token) == false)
        #expect(
            try await credentialStore.staticTokens(
                for: [relay],
                accountID: "account-a"
            )[relay.id] == token
        )
        #expect(
            try await credentialStore.staticTokens(
                for: [relay],
                accountID: "account-b"
            ).isEmpty
        )
        let movedRelay = try CmxIrohCustomRelayDefinition(
            id: relay.id,
            url: "https://replacement.example.net/",
            provider: relay.provider,
            region: relay.region,
            authMode: relay.authMode
        )
        #expect(
            try await credentialStore.staticTokens(
                for: [movedRelay],
                accountID: "account-a"
            ).isEmpty
        )
        #expect(
            await secureStore.observedAccessibilities()
                == [.afterFirstUnlockThisDeviceOnly]
        )
    }

    @Test
    func missingStaticTokenDisablesWholeCustomProfileWithoutManagedFallback() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let stores = makeStores()
        let openRelay = try CmxIrohCustomRelayDefinition(
            id: "open-relay",
            url: "https://open.example.net/",
            provider: "personal",
            region: "home",
            authMode: .none
        )
        let authenticatedRelay = try CmxIrohCustomRelayDefinition(
            id: "authenticated-relay",
            url: "https://authenticated.example.net/",
            provider: "personal",
            region: "home",
            authMode: .staticToken
        )

        let effective = try await stores.service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: .custom([openRelay, authenticatedRelay]),
                preferenceRevision: 1
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        #expect(effective.source == .customUnavailable)
        #expect(effective.endpointRelayProfile.allowedRelayURLs.isEmpty)
        #expect(effective.endpointRelayProfile.activeRelays.isEmpty)
        #expect(effective.relayBootstrap == nil)
        #expect(effective.missingCredentialRelayIDs == [authenticatedRelay.id])
        #expect(await stores.service.diagnosticsSnapshot().failure == .missingCustomCredential)
    }

    @Test
    func dormantSelectionsAndCustomDefinitionsSurviveEveryActiveMode() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let stores = makeStores()
        let relay = try CmxIrohCustomRelayDefinition(
            id: "private-home",
            url: "https://relay.example.net/",
            provider: "personal",
            region: "home",
            authMode: .none
        )
        let configuration = try CmxIrohAccountRelayConfiguration(
            mode: .automatic,
            selectedManagedRelayIDs: ["cmux-us"],
            customRelays: [relay]
        )

        let effective = try await stores.service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: configuration,
                preferenceRevision: 1
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        #expect(effective.requestedConfiguration == configuration)
        #expect(effective.requestedPreference == .automatic)
        #expect(effective.source == .managed)
        let managed = try configuration.updatingActivePreference(.managed(["cmux-us"]))
        #expect(managed.customRelays == [relay])
        let custom = try managed.updatingActivePreference(.custom([relay]))
        #expect(custom.selectedManagedRelayIDs == ["cmux-us"])
        #expect(custom.customRelays == [relay])
    }

    @Test
    func authoritativeDeletionPrunesDeviceSecretWithoutChangingDormantMode() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let credentialStore = CmxIrohCustomRelayCredentialStore(
            secureStore: TestSecureCredentialStore()
        )
        let service = CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: CmxIrohRelayPreferenceStore(secureStore: TestSecureCredentialStore()),
            credentialStore: credentialStore
        )
        let relay = try CmxIrohCustomRelayDefinition(
            id: "private-home",
            url: "https://relay.example.net/",
            provider: "personal",
            region: "home",
            authMode: .staticToken
        )
        try await credentialStore.setStaticToken(
            "device-only-token",
            relayID: relay.id,
            relayURL: relay.url,
            accountID: "account-a"
        )
        let saved = try CmxIrohAccountRelayConfiguration(
            mode: .automatic,
            selectedManagedRelayIDs: ["cmux-us"],
            customRelays: [relay]
        )
        _ = try await service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: saved,
                preferenceRevision: 1
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )
        #expect(
            try await credentialStore.staticTokens(
                for: [relay],
                accountID: "account-a"
            )[relay.id] != nil
        )

        let removed = try saved.replacingCustomRelays([])
        _ = try await service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 2),
                preference: removed,
                preferenceRevision: 2
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        #expect(removed.mode == .automatic)
        #expect(removed.selectedManagedRelayIDs == ["cmux-us"])
        #expect(
            try await credentialStore.staticTokens(
                for: [relay],
                accountID: "account-a"
            ).isEmpty
        )
    }

    @Test
    func committedRemoteConfigurationWinsWhenLocalPersistenceFails() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let preferenceSecureStore = TestControllableSecureCredentialStore()
        await preferenceSecureStore.failNextWrite()
        let first = try CmxIrohAccountRelayConfiguration(
            mode: .automatic,
            selectedManagedRelayIDs: ["cmux-us"],
            customRelays: []
        )
        let second = try first.updatingActivePreference(.managed(["cmux-us"]))
        let broker = RelayPolicyServiceBroker(responses: [
            try CmxIrohRelayPreferenceResponse(preference: first, revision: 1),
            try CmxIrohRelayPreferenceResponse(preference: second, revision: 2),
        ])
        let service = CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: CmxIrohRelayPreferenceStore(secureStore: preferenceSecureStore),
            credentialStore: CmxIrohCustomRelayCredentialStore(
                secureStore: TestSecureCredentialStore()
            ),
            broker: broker
        )

        let reconciled = try await service.setConfiguration(
            first,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )
        #expect(reconciled.requestedConfiguration == first)
        #expect(reconciled.preferenceRevision == 1)
        #expect(await service.accountConfiguration() == first)
        #expect(await service.diagnosticsSnapshot().failure == .preferencePersistenceUnavailable)

        _ = try await service.setConfiguration(
            second,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )
        #expect(await broker.expectedRevisions() == [nil, 1])
        #expect(await service.accountConfiguration() == second)
    }

    @Test
    func liveAuthoritativeRevisionAllowsUpdatesWhilePreferenceKeychainIsUnavailable() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let preferenceSecureStore = RelayPolicyServiceSwitchableSecureStore()
        let initial = try CmxIrohAccountRelayConfiguration(
            mode: .automatic,
            selectedManagedRelayIDs: ["cmux-us"],
            customRelays: []
        )
        let updated = try initial.updatingActivePreference(.managed(["cmux-us"]))
        let broker = RelayPolicyServiceBroker(responses: [
            try CmxIrohRelayPreferenceResponse(preference: updated, revision: 2),
        ])
        let service = CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: CmxIrohRelayPreferenceStore(secureStore: preferenceSecureStore),
            credentialStore: CmxIrohCustomRelayCredentialStore(
                secureStore: TestSecureCredentialStore()
            ),
            broker: broker
        )
        _ = try await service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: initial,
                preferenceRevision: 1
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )
        await preferenceSecureStore.setUnavailable(true)

        let effective = try await service.setConfiguration(
            updated,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )

        #expect(effective.requestedConfiguration == updated)
        #expect(await broker.expectedRevisions() == [1])
        #expect(await service.diagnosticsSnapshot().failure == .preferencePersistenceUnavailable)
    }

    @Test
    func relayURLChangeQuarantinesOldDeviceSecretUntilReauthenticated() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let oldRelay = try CmxIrohCustomRelayDefinition(
            id: "private-home",
            url: "https://old-relay.example.net/",
            provider: "personal",
            region: "home",
            authMode: .staticToken
        )
        let newRelay = try CmxIrohCustomRelayDefinition(
            id: oldRelay.id,
            url: "https://new-relay.example.net/",
            provider: oldRelay.provider,
            region: oldRelay.region,
            authMode: .staticToken
        )
        let oldConfiguration = try CmxIrohAccountRelayConfiguration.custom([oldRelay])
        let newConfiguration = try CmxIrohAccountRelayConfiguration.custom([newRelay])
        let credentialStore = CmxIrohCustomRelayCredentialStore(
            secureStore: TestSecureCredentialStore()
        )
        let broker = RelayPolicyServiceBroker(responses: [
            try CmxIrohRelayPreferenceResponse(
                preference: newConfiguration,
                revision: 2
            ),
        ])
        let service = CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: CmxIrohRelayPreferenceStore(
                secureStore: TestSecureCredentialStore()
            ),
            credentialStore: credentialStore,
            broker: broker
        )
        _ = try await service.install(
            response: CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: oldConfiguration,
                preferenceRevision: 1
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )
        let oldActive = try await service.setStaticCredential(
            "old-provider-secret",
            relayID: oldRelay.id,
            relayURL: oldRelay.url,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )
        #expect(oldActive.endpointRelayProfile.activeRelays.first?.authenticationToken
            == "old-provider-secret")

        let quarantined = try await service.setConfiguration(
            newConfiguration,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )

        #expect(quarantined.source == .customUnavailable)
        #expect(quarantined.endpointRelayProfile.allowedRelayURLs.isEmpty)
        #expect(quarantined.missingCredentialRelayIDs == [newRelay.id])
        #expect(try await credentialStore.configuredRelayIDs(accountID: "account-a").isEmpty)

        let reauthenticated = try await service.setStaticCredential(
            "new-provider-secret",
            relayID: newRelay.id,
            relayURL: newRelay.url,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )
        #expect(reauthenticated.source == .custom)
        #expect(reauthenticated.endpointRelayProfile.allowedRelayURLs == [newRelay.url])
        #expect(reauthenticated.endpointRelayProfile.activeRelays.first?.authenticationToken
            == "new-provider-secret")
    }
}
