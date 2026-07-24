import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh broker credential repository")
struct CmxIrohBrokerCredentialRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let relayFleet = [
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]

    @Test("credential descriptions redact opaque tokens")
    func credentialDescriptionsRedactTokens() {
        let credential = relayResponse().credentials[0]

        #expect(!String(describing: credential).contains(credential.token))
        #expect(!String(reflecting: credential).contains(credential.token))
        #expect(String(describing: credential).contains("<redacted>"))
    }

    @Test("binding metadata and relay credentials survive repository recreation")
    func roundTripsDurableState() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let binding = try metadata()
        let response = relayResponse()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)

        try await repository.saveBinding(binding, accountID: "account-a")
        try await repository.saveRelayCredential(
            response,
            accountID: "account-a",
            binding: binding,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )

        let recreated = makeRepository(defaults: defaults, secureStore: secureStore)
        #expect(
            try await recreated.loadBinding(
                accountID: "account-a",
                appInstanceID: binding.appInstanceID
            ) == binding
        )
        #expect(
            try await recreated.loadRelayCredential(
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: Set(relayFleet),
                now: now
            ) == response
        )
        #expect(
            await secureStore.observedAccessibilities()
                == [.afterFirstUnlockThisDeviceOnly]
        )
        #expect(
            !defaults.dictionaryRepresentation().values.contains(where: { value in
                response.credentials.contains { credential in
                    String(describing: value).contains(credential.token)
                }
            })
        )
    }

    @Test("distinct per-relay credentials survive device-only persistence")
    func roundTripsDistinctPerRelayCredentials() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let binding = try metadata()
        let response = CmxIrohRelayTokenResponse(credentials: [
            CmxIrohManagedRelayCredential(
                relayURL: relayFleet[0],
                token: "abc234",
                expiresAt: iso8601(now.addingTimeInterval(2 * 60 * 60)),
                refreshAfter: iso8601(now.addingTimeInterval(60 * 60))
            ),
            CmxIrohManagedRelayCredential(
                relayURL: relayFleet[1],
                token: "def567",
                expiresAt: iso8601(now.addingTimeInterval(3 * 60 * 60)),
                refreshAfter: iso8601(now.addingTimeInterval(90 * 60))
            ),
        ])
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)

        try await repository.saveBinding(binding, accountID: "account-a")
        try await repository.saveRelayCredential(
            response,
            accountID: "account-a",
            binding: binding,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )

        #expect(
            try await repository.loadRelayCredential(
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: Set(relayFleet),
                now: now
            ) == response
        )
        let stored = try #require(await secureStore.onlyStoredData())
        let object = try #require(
            JSONSerialization.jsonObject(with: stored) as? [String: Any]
        )
        #expect(object["version"] as? Int == 2)
        #expect(object["token"] == nil)
        #expect(object["response"] != nil)
    }

    @Test("version-one homogeneous credentials migrate without a new network mint")
    func loadsVersionOneCredentialRecord() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let binding = try metadata()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let legacyResponse = relayResponse()

        try await repository.saveBinding(binding, accountID: "account-a")
        try await repository.saveRelayCredential(
            legacyResponse,
            accountID: "account-a",
            binding: binding,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )
        let account = try #require(await secureStore.lastDeletedOrWrittenAccount())
        let bindingObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(binding)
        )
        let legacyRecord: [String: Any] = [
            "version": 1,
            "binding": bindingObject,
            "token": "abc234",
            "expiresAt": iso8601(now.addingTimeInterval(2 * 60 * 60)),
            "refreshAfter": iso8601(now.addingTimeInterval(60 * 60)),
            "relayFleet": relayFleet,
        ]
        await secureStore.seed(
            try JSONSerialization.data(withJSONObject: legacyRecord),
            account: account
        )

        #expect(
            try await repository.loadRelayCredential(
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: Set(relayFleet),
                now: now
            ) == legacyResponse
        )
    }

    @Test("a different account or app instance cannot resurrect prior state")
    func scopeRotationDeletesPriorState() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let original = try metadata()

        try await repository.saveBinding(original, accountID: "account-a")
        try await repository.saveRelayCredential(
            relayResponse(),
            accountID: "account-a",
            binding: original,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )

        #expect(
            try await repository.loadBinding(
                accountID: "account-b",
                appInstanceID: original.appInstanceID
            ) == nil
        )
        #expect(await secureStore.recordCount() == 0)

        let replacementAppInstanceID = "123e4567-e89b-42d3-a456-426614174099"
        #expect(
            try await repository.loadBinding(
                accountID: "account-b",
                appInstanceID: replacementAppInstanceID
            ) == nil
        )
        #expect(
            try await repository.loadBinding(
                accountID: "account-a",
                appInstanceID: original.appInstanceID
            ) == nil
        )
        #expect(await secureStore.deleteAllCount() == 4)
    }

    @Test("replacing the exact broker binding invalidates its relay capability")
    func bindingRotationDeletesRelayCredential() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let original = try metadata()
        let rotated = try metadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174020",
            endpointByte: "cd",
            generation: 2
        )

        try await repository.saveBinding(original, accountID: "account-a")
        try await repository.saveRelayCredential(
            relayResponse(),
            accountID: "account-a",
            binding: original,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )
        try await repository.saveBinding(rotated, accountID: "account-a")

        #expect(
            try await repository.loadBinding(
                accountID: "account-a",
                appInstanceID: original.appInstanceID
            ) == rotated
        )
        #expect(await secureStore.recordCount() == 0)
        #expect(
            try await repository.loadRelayCredential(
                accountID: "account-a",
                binding: original,
                expectedRelayFleet: Set(relayFleet),
                now: now
            ) == nil
        )
    }

    @Test("saving an incomplete relay fleet fails without persisting the token")
    func saveRejectsFleetMismatch() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let binding = try metadata()
        try await repository.saveBinding(binding, accountID: "account-a")

        await #expect(
            throws: CmxIrohBrokerCredentialRepositoryError.relayFleetMismatch
        ) {
            try await repository.saveRelayCredential(
                relayResponse(relayFleet: [relayFleet[0]]),
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: Set(relayFleet),
                now: now
            )
        }
        #expect(await secureStore.recordCount() == 0)
    }

    @Test("loading with a changed managed fleet deletes the stale capability")
    func loadRejectsFleetMismatch() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let binding = try metadata()
        try await repository.saveBinding(binding, accountID: "account-a")
        try await repository.saveRelayCredential(
            relayResponse(),
            accountID: "account-a",
            binding: binding,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )

        #expect(
            try await repository.loadRelayCredential(
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: Set([relayFleet[0]]),
                now: now
            ) == nil
        )
        #expect(await secureStore.recordCount() == 0)
    }

    @Test("expired or refresh-stale relay capabilities are deleted")
    func loadRejectsStaleCredential() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let binding = try metadata()
        let response = relayResponse()
        try await repository.saveBinding(binding, accountID: "account-a")
        try await repository.saveRelayCredential(
            response,
            accountID: "account-a",
            binding: binding,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )

        #expect(
            try await repository.loadRelayCredential(
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: Set(relayFleet),
                now: now.addingTimeInterval(60 * 60)
            ) == nil
        )
        #expect(await secureStore.recordCount() == 0)

        try await repository.saveRelayCredential(
            response,
            accountID: "account-a",
            binding: binding,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )
        #expect(
            try await repository.loadRelayCredential(
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: Set(relayFleet),
                now: now.addingTimeInterval(2 * 60 * 60)
            ) == nil
        )
        #expect(await secureStore.recordCount() == 0)
    }

    @Test("corrupt secure records fail closed and are removed")
    func corruptCredentialIsDeleted() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let binding = try metadata()
        try await repository.saveBinding(binding, accountID: "account-a")
        try await repository.saveRelayCredential(
            relayResponse(),
            accountID: "account-a",
            binding: binding,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )
        let account = try #require(await secureStore.lastDeletedOrWrittenAccount())
        await secureStore.seed(Data("not-json".utf8), account: account)

        #expect(
            try await repository.loadRelayCredential(
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: Set(relayFleet),
                now: now
            ) == nil
        )
        #expect(await secureStore.recordCount() == 0)
    }

    @Test("persisted binding metadata is revalidated during decoding")
    func corruptBindingMetadataIsRejected() throws {
        let binding = try metadata()
        let encoded = try JSONEncoder().encode(binding)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["bindingID"] = "not-a-uuid"
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: CmxIrohBrokerCredentialRepositoryError.invalidBinding) {
            try JSONDecoder().decode(
                CmxIrohBrokerBindingMetadata.self,
                from: corrupted
            )
        }
    }

    @Test("explicit deletion preserves or clears binding metadata as requested")
    func explicitDeletion() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let binding = try metadata()
        try await repository.saveBinding(binding, accountID: "account-a")
        try await repository.saveRelayCredential(
            relayResponse(),
            accountID: "account-a",
            binding: binding,
            expectedRelayFleet: Set(relayFleet),
            now: now
        )

        try await repository.deleteRelayCredential(
            accountID: "account-a",
            appInstanceID: binding.appInstanceID
        )
        #expect(await secureStore.recordCount() == 0)
        #expect(
            try await repository.loadBinding(
                accountID: "account-a",
                appInstanceID: binding.appInstanceID
            ) == binding
        )

        try await repository.deleteBinding(
            accountID: "account-a",
            appInstanceID: binding.appInstanceID
        )
        #expect(
            try await repository.loadBinding(
                accountID: "account-a",
                appInstanceID: binding.appInstanceID
            ) == nil
        )

        try await repository.saveBinding(binding, accountID: "account-a")
        try await repository.deactivate()
        #expect(
            try await repository.loadBinding(
                accountID: "account-a",
                appInstanceID: binding.appInstanceID
            ) == nil
        )
    }

    private func makeRepository(
        defaults: UserDefaults,
        secureStore: TestSecureCredentialStore
    ) -> CmxIrohBrokerCredentialRepository {
        CmxIrohBrokerCredentialRepository(
            secureStore: secureStore,
            installState: CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        )
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "CmxIrohBrokerCredentialRepositoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func metadata(
        bindingID: String = "123e4567-e89b-42d3-a456-426614174010",
        endpointByte: String = "ab",
        generation: Int = 1
    ) throws -> CmxIrohBrokerBindingMetadata {
        try CmxIrohBrokerBindingMetadata(
            bindingID: bindingID,
            deviceID: "123e4567-e89b-42d3-a456-426614174011",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174012",
            tag: "cmux-ios-v0",
            platform: .mac,
            endpointID: CmxIrohPeerIdentity(
                endpointID: String(repeating: endpointByte, count: 32)
            ),
            identityGeneration: generation
        )
    }

    private func relayResponse(
        relayFleet: [String]? = nil
    ) -> CmxIrohRelayTokenResponse {
        CmxIrohRelayTokenResponse(
            token: "abc234",
            expiresAt: iso8601(now.addingTimeInterval(2 * 60 * 60)),
            refreshAfter: iso8601(now.addingTimeInterval(60 * 60)),
            relayFleet: relayFleet ?? self.relayFleet
        )
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
