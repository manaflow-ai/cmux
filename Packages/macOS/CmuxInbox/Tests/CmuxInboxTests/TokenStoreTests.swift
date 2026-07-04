import CmuxInbox
import Foundation
import Testing

/// Simulates a Keychain rejecting every operation, e.g. tagged Debug builds
/// failing with errSecMissingEntitlement (-34018).
private actor RejectingTokenStore: InboxTokenStoring {
    func saveToken(_ token: Data, source: InboxSource, accountID: String) async throws {
        throw InboxError.credentialStoreFailed("Keychain save failed (-34018)")
    }

    func token(source: InboxSource, accountID: String) async throws -> Data? {
        throw InboxError.credentialStoreFailed("Keychain read failed (-34018)")
    }

    func deleteToken(source: InboxSource, accountID: String) async throws {
        throw InboxError.credentialStoreFailed("Keychain delete failed (-34018)")
    }

    func credentialState(source: InboxSource, accountID: String) async -> InboxCredentialState {
        .inaccessible
    }
}

@Suite("Token stores")
struct TokenStoreTests {
    private func temporaryVaultURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-inbox-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("inbox-tokens.json", isDirectory: false)
    }

    @Test func fileVaultRoundTripsTokensWithOwnerOnlyPermissions() async throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let vault = InboxFileTokenVault(fileURL: url)

        try await vault.saveToken(Data("xoxb-secret".utf8), source: .slack, accountID: "default")
        let loaded = try await vault.token(source: .slack, accountID: "default")
        #expect(loaded == Data("xoxb-secret".utf8))
        #expect(await vault.credentialState(source: .slack, accountID: "default") == .present)
        #expect(await vault.credentialState(source: .gmail, accountID: "me") == .missing)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
        // The 0600 temp file used for the atomic swap must not linger.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == [url.lastPathComponent])

        try await vault.deleteToken(source: .slack, accountID: "default")
        #expect(try await vault.token(source: .slack, accountID: "default") == nil)
        #expect(await vault.credentialState(source: .slack, accountID: "default") == .missing)
    }

    @Test func fileVaultSurfacesCorruptionAsCredentialStoreFailure() async throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let vault = InboxFileTokenVault(fileURL: url)

        await #expect(throws: InboxError.self) {
            _ = try await vault.token(source: .slack, accountID: "default")
        }
        #expect(await vault.credentialState(source: .slack, accountID: "default") == .inaccessible)
    }

    @Test func layeredStoreFallsBackWhenPrimaryRejectsWrites() async throws {
        let fallback = MemoryTokenStore()
        let layered = InboxLayeredTokenStore(primary: RejectingTokenStore(), fallback: fallback)

        try await layered.saveToken(Data("token".utf8), source: .gmail, accountID: "me")
        #expect(try await layered.token(source: .gmail, accountID: "me") == Data("token".utf8))
        #expect(await layered.credentialState(source: .gmail, accountID: "me") == .present)

        try await layered.deleteToken(source: .gmail, accountID: "me")
        #expect(try await layered.token(source: .gmail, accountID: "me") == nil)
        #expect(await layered.credentialState(source: .gmail, accountID: "me") != .present)
    }

    @Test func layeredStorePrefersPrimaryAndClearsStaleFallbackCopy() async throws {
        let primary = MemoryTokenStore()
        let fallback = MemoryTokenStore(tokens: ["gmail:me": "stale"])
        let layered = InboxLayeredTokenStore(primary: primary, fallback: fallback)

        try await layered.saveToken(Data("fresh".utf8), source: .gmail, accountID: "me")
        #expect(try await layered.token(source: .gmail, accountID: "me") == Data("fresh".utf8))
        #expect(try await fallback.token(source: .gmail, accountID: "me") == nil)

        try await layered.deleteToken(source: .gmail, accountID: "me")
        #expect(await layered.credentialState(source: .gmail, accountID: "me") == .missing)
    }

    @Test func connectStoresTokenThroughLayeredStoreDespiteRejectingPrimary() async throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let layered = InboxLayeredTokenStore(
            primary: RejectingTokenStore(),
            fallback: InboxFileTokenVault(fileURL: url)
        )
        let store = try InboxSQLiteStore(databaseURL: InboxFixtures().temporaryDatabaseURL())
        let hub = IntegrationHub(store: store, connectors: [], tokenStore: layered)

        let status = try await hub.connect(source: .slack, accountID: "default", token: "xoxb-live")
        #expect(status.credentialState == .present)
        #expect(status.status != .missingCredentials)
    }
}
