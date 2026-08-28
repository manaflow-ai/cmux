import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh broker credential repository")
struct CmxIrohBrokerCredentialRepositoryTests {
    private let relayFleet = [
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]

    @Test("binding metadata survives repository recreation")
    func roundTripsDurableState() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let pathHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: relayFleet[0],
            source: .native,
            privacyScope: .publicInternet
        )
        let binding = try metadata(pathHints: [pathHint])
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)

        try await repository.saveBinding(binding, accountID: "account-a")

        let recreated = makeRepository(defaults: defaults, secureStore: secureStore)
        #expect(
            try await recreated.loadBinding(
                accountID: "account-a",
                appInstanceID: binding.appInstanceID
            ) == binding
        )
        // Tokenless transport: nothing is ever written to secure storage.
        #expect(await secureStore.recordCount() == 0)
    }

    @Test("scope rotation deletes prior state and legacy secure records")
    func scopeRotationDeletesPriorState() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let binding = try metadata()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        try await repository.saveBinding(binding, accountID: "account-a")
        // A legacy relay-credential record left behind by a token-era build.
        try await secureStore.write(
            Data("legacy-token".utf8),
            account: "legacy-scope",
            accessibility: .afterFirstUnlockThisDeviceOnly
        )

        #expect(
            try await repository.loadBinding(
                accountID: "account-b",
                appInstanceID: binding.appInstanceID
            ) == nil
        )
        #expect(await secureStore.recordCount() == 0)
        #expect(
            try await repository.loadBinding(
                accountID: "account-a",
                appInstanceID: binding.appInstanceID
            ) == nil
        )
    }

    @Test("binding replacement deletes any legacy token-era secure record")
    func bindingRotationDeletesLegacySecureRecord() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let binding = try metadata()
        try await repository.saveBinding(binding, accountID: "account-a")
        // A token-era build stored the relay credential under the scope key.
        try await secureStore.write(
            Data("legacy-token".utf8),
            account: scope(accountID: "account-a", appInstanceID: binding.appInstanceID),
            accessibility: .afterFirstUnlockThisDeviceOnly
        )

        let replacement = try metadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174020",
            endpointByte: "cd",
            generation: 2
        )
        try await repository.saveBinding(replacement, accountID: "account-a")

        #expect(await secureStore.recordCount() == 0)
        #expect(
            try await repository.loadBinding(
                accountID: "account-a",
                appInstanceID: replacement.appInstanceID
            ) == replacement
        )
    }

    @Test("explicit deletion and deactivation clear binding metadata")
    func explicitDeletion() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStore = TestSecureCredentialStore()
        let repository = makeRepository(defaults: defaults, secureStore: secureStore)
        let binding = try metadata()
        try await repository.saveBinding(binding, accountID: "account-a")

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

    /// Mirrors the repository's deterministic scope derivation so a test can
    /// seed a record where a token-era build would have stored it.
    private func scope(accountID: String, appInstanceID: String) -> String {
        let transcript = Data(
            "cmux/iroh/broker-credential-scope/v1\0\(accountID)\0\(appInstanceID)".utf8
        )
        return SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined()
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
        generation: Int = 1,
        pathHints: [CmxIrohPathHint] = []
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
            identityGeneration: generation,
            pathHints: pathHints
        )
    }
}
