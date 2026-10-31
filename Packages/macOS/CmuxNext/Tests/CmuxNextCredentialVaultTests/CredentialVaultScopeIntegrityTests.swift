import CmuxNextCompat
@testable import CmuxNextCredentialVault
import Foundation
import Testing

/// Agent processes share the person's filesystem permissions; the index is a display cache,
/// never an authority for whether the app releases a Keychain value.
@MainActor struct CredentialVaultScopeIntegrityTests {
    private let person = CredentialVault.Caller(consumer: .user, label: "you")
    private let agent = CredentialVault.Caller(consumer: .agents, label: "agent")

    private func vault() -> CredentialVault {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vault-integrity-\(UUID().uuidString)")
        return CredentialVault(secrets: CredentialVaultControlTests.MemorySecrets(), folder: folder)
    }

    private func widenIndex(_ vault: CredentialVault) throws {
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: vault.indexURL)) as? [String: Any])
        var entries = try #require(document["secrets"] as? [String: [String: Any]])
        var entry = try #require(entries["PROD_DB"])
        entry["scope"] = ["user", "agents"]
        entries["PROD_DB"] = entry
        document["secrets"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: vault.indexURL, options: .atomic)
    }

    private func expectKeptForPerson(_ vault: CredentialVault) throws {
        #expect(try vault.list()["PROD_DB"]?.scope == [.user])
        #expect(throws: CredentialVault.Failure.denied(["PROD_DB"], .agents)) {
            try vault.resolve(["PROD_DB"], for: agent, command: nil, approved: [])
        }
        #expect(throws: CredentialVault.Failure.needsApproval(["PROD_DB"])) {
            try vault.resolve(["PROD_DB"], for: person, command: nil, approved: [])
        }
    }

    @Test func aWritableIndexCannotEnableAgentsOrSuppressApproval() throws {
        let vault = vault()
        try vault.set("PROD_DB", value: "postgres://private-value", scope: [.user], note: nil, by: person)
        try widenIndex(vault)
        try expectKeptForPerson(vault)
    }

    @Test func aReplayedIndexCannotRestoreARevokedScope() throws {
        let vault = vault()
        try vault.set("PROD_DB", value: "postgres://private-value", scope: [.user, .agents], note: nil, by: person)
        let oldIndex = try Data(contentsOf: vault.indexURL)
        try vault.setScope("PROD_DB", scope: [.user], by: person)
        try oldIndex.write(to: vault.indexURL, options: .atomic)
        try expectKeptForPerson(vault)
    }

    @Test(arguments: [Int.max, Int.min, -1])
    func anUntrustedUsageCountCannotCrashAnAllowedRead(uses: Int) throws {
        let vault = vault()
        try vault.set("PROD_DB", value: "postgres://private-value", scope: [.user], note: nil, by: person)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: vault.indexURL)) as? [String: Any])
        var entries = try #require(document["secrets"] as? [String: [String: Any]])
        var entry = try #require(entries["PROD_DB"])
        entry["uses"] = uses
        entries["PROD_DB"] = entry
        document["secrets"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: vault.indexURL, options: .atomic)

        #expect(try vault.resolve(["PROD_DB"], for: person, command: nil)["PROD_DB"] == "postgres://private-value")
        #expect(try vault.list()["PROD_DB"]?.uses == (uses == Int.max ? Int.max : 1))
    }

    @Test func aMissingCacheEntryNeverLetsAddReplaceAProtectedSecret() throws {
        let vault = vault()
        try vault.set("PROD_DB", value: "postgres://private-value", scope: [.user], note: nil, by: person)
        let originalIndex = try Data(contentsOf: vault.indexURL)
        var document = try #require(JSONSerialization.jsonObject(with: originalIndex) as? [String: Any])
        document["secrets"] = [String: Any]()
        try JSONSerialization.data(withJSONObject: document).write(to: vault.indexURL, options: .atomic)
        #expect(throws: CredentialVault.Failure.exists("PROD_DB")) {
            try vault.set("PROD_DB", value: "replacement-value", scope: [.user, .agents], note: nil,
                          by: person, onlyNew: true)
        }
        try originalIndex.write(to: vault.indexURL, options: .atomic)
        try expectKeptForPerson(vault)
        #expect(try vault.resolve(["PROD_DB"], for: person, command: nil)["PROD_DB"] == "postgres://private-value")
    }

    @Test func aFailedScopeWriteRestoresTheProtectedScope() throws {
        let vault = vault()
        try vault.set("PROD_DB", value: "postgres://private-value", scope: [.user], note: nil, by: person)
        let folder = vault.indexURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        #expect(throws: CredentialVault.Failure.self) { try vault.setScope("PROD_DB", scope: [.user, .agents], by: person) }
        try expectKeptForPerson(vault)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try widenIndex(vault)
        try expectKeptForPerson(vault)
    }

    @Test func aFailedReplacementRestoresTheValueAndScopeTogether() throws {
        let vault = vault()
        try vault.set("PROD_DB", value: "postgres://private-value", scope: [.user], note: nil, by: person)
        let folder = vault.indexURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        #expect(throws: CredentialVault.Failure.self) {
            try vault.set("PROD_DB", value: "replacement-value", scope: [.user, .agents], note: nil, by: person)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try expectKeptForPerson(vault)
        #expect(try vault.resolve(["PROD_DB"], for: person, command: nil)["PROD_DB"] == "postgres://private-value")
    }
}
