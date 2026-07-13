import CMUXMobileCore
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
        #expect(effective.relayBootstrap == fixture.relayCredential())
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
        #expect(directOnly.relayBootstrap == nil)
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
    func stalledRelayPolicyLoadCannotDelayTCPStartup() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let trustRoot = try fixture.firstTrustRoot
        let secureStore = RelayPolicyServiceSuspendedSecureStore()
        let service = CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(
                secureStore: TestSecureCredentialStore()
            ),
            preferenceStore: CmxIrohRelayPreferenceStore(
                secureStore: secureStore
            ),
            credentialStore: CmxIrohCustomRelayCredentialStore(
                secureStore: TestSecureCredentialStore()
            )
        )
        let tcpState = RelayPolicyServiceTCPState()
        var activation: Task<Void, Never>?

        CmxIrohTCPFirstActivation.start(
            startTCP: { tcpState.markStarted() },
            scheduleIroh: {
                activation = Task {
                    _ = await service.restore(
                        accountID: "account-a",
                        trustRoot: trustRoot,
                        relayCredential: nil,
                        now: Date()
                    )
                }
            }
        )

        await secureStore.waitUntilReadStarts()
        #expect(tcpState.started)
        #expect(activation != nil)

        await secureStore.resumeRead()
        await activation?.value
        #expect(await service.diagnosticsSnapshot().source == .managedUnavailable)
        #expect(await service.diagnosticsSnapshot().failure == .policyUnavailable)
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
        #expect(try await credentialStore.staticTokens(accountID: "account-a")[relay.id] != nil)

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
        #expect(try await credentialStore.staticTokens(accountID: "account-a").isEmpty)
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

private final class RelayPolicyServiceTCPState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var started: Bool {
        lock.withLock { value }
    }

    func markStarted() {
        lock.withLock { value = true }
    }
}

private actor RelayPolicyServiceSuspendedSecureStore: CmxIrohSecureCredentialStoring {
    private var readStartedContinuation: CheckedContinuation<Void, Never>?
    private var readContinuation: CheckedContinuation<Data?, Never>?
    private var didStartRead = false

    func read(account _: String) async throws -> Data? {
        didStartRead = true
        readStartedContinuation?.resume()
        readStartedContinuation = nil
        return await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
    }

    func waitUntilReadStarts() async {
        guard !didStartRead else { return }
        await withCheckedContinuation { continuation in
            readStartedContinuation = continuation
        }
    }

    func resumeRead() {
        readContinuation?.resume(returning: nil)
        readContinuation = nil
    }

    func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) async throws {}

    func delete(account: String) async throws {}
    func deleteAll() async throws {}
}

private actor RelayPolicyServiceSwitchableSecureStore: CmxIrohSecureCredentialStoring {
    private struct Unavailable: Error {}
    private var records: [String: Data] = [:]
    private var unavailable = false

    func setUnavailable(_ unavailable: Bool) {
        self.unavailable = unavailable
    }

    func read(account: String) throws -> Data? {
        guard !unavailable else { throw Unavailable() }
        return records[account]
    }

    func write(
        _ data: Data,
        account: String,
        accessibility _: CmxIrohSecureCredentialAccessibility
    ) throws {
        guard !unavailable else { throw Unavailable() }
        records[account] = data
    }

    func delete(account: String) throws {
        guard !unavailable else { throw Unavailable() }
        records.removeValue(forKey: account)
    }

    func deleteAll() throws {
        guard !unavailable else { throw Unavailable() }
        records.removeAll(keepingCapacity: false)
    }
}

private actor RelayPolicyServiceBroker: CmxIrohRelayPolicyServing {
    private enum Failure: Error { case exhausted, unsupported }

    private var responses: [CmxIrohRelayPreferenceResponse]
    private var requests: [CmxIrohRelayPreferenceUpdateRequest] = []

    init(responses: [CmxIrohRelayPreferenceResponse]) {
        self.responses = responses
    }

    func issueRelayBootstrap(
        endpointID _: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayBootstrapResponse {
        throw Failure.unsupported
    }

    func relayPreference() async throws -> CmxIrohRelayPreferenceResponse {
        guard let response = responses.first else { throw Failure.exhausted }
        return response
    }

    func updateRelayPreference(
        _ request: CmxIrohRelayPreferenceUpdateRequest
    ) async throws -> CmxIrohRelayPreferenceResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw Failure.exhausted }
        return responses.removeFirst()
    }

    func expectedRevisions() -> [Int64?] {
        requests.map(\.expectedRevision)
    }
}
