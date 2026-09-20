#if os(iOS)
import Foundation
import Security
import Testing
@testable import CmuxRemoteConnections

/// Signed iOS-only integration checks for the real Data Protection Keychain.
///
/// The suite deliberately fails when the test runner has no exact access-group
/// entitlement. A macOS package run does not contain this suite; the hosted
/// iOS workflow must therefore name these tests explicitly in its xcresult.
@Suite struct MobileRemoteKeychainNativeIntegrationTests {
    @Test func signedDataProtectionKeychainSupportsCrudWithoutPrompt() async throws {
        let store = try makeStore()
        let scope = try makeScope()
        let original = MobileRemoteSecretValue(bytes: Data("native-test-value".utf8))
        let replacement = MobileRemoteSecretValue(bytes: Data("native-replacement".utf8))

        try await store.insert(
            original, scope: scope, protection: .whenUnlockedThisDeviceOnly
        )
        guard try await store.read(scope: scope).bytes == original.bytes else {
            try? await store.delete(scope: scope)
            Issue.record("Native Keychain returned a value different from the inserted bytes")
            return
        }
        try await store.updateValue(replacement, scope: scope)
        #expect(try await store.read(scope: scope).bytes == replacement.bytes)
        try await store.delete(scope: scope)
        await #expect(throws: MobileRemoteSecretStoreError.itemNotFound) {
            _ = try await store.read(scope: scope)
        }
    }

    @Test func signedDataProtectionKeychainKeepsScopesIsolated() async throws {
        let store = try makeStore()
        let first = try makeScope()
        let otherItem = try MobileRemoteSecretScope(
            accountID: first.accountID, vaultID: first.vaultID, itemID: UUID()
        )
        try await store.insert(
            MobileRemoteSecretValue(bytes: Data("scope-one".utf8)),
            scope: first,
            protection: .whenUnlockedThisDeviceOnly
        )
        await #expect(throws: MobileRemoteSecretStoreError.itemNotFound) {
            _ = try await store.read(scope: otherItem)
        }
        #expect(try await store.read(scope: first).bytes == Data("scope-one".utf8))
        try await store.delete(scope: first)
    }

    private func makeStore() throws -> MobileRemoteKeychainSecretStore {
        guard let group = signedAccessGroup() else {
            throw MobileRemoteKeychainNativeTestError.missingExactAccessGroup
        }
        return MobileRemoteKeychainSecretStore(
            namespace: try MobileRemoteKeychainNamespace(accessGroup: group)
        )
    }

    private func signedAccessGroup() -> String? {
        // The hosted script checks the signed entitlement against this value
        // before launching. SecTask is not public iOS API. The native CRUD
        // tests must still prove real access, with no alternate group fallback.
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CMUXRemoteTestKeychainGroup") as? String,
              !group.isEmpty, !group.contains("*"), !group.contains("$") else { return nil }
        return group
    }

    private func makeScope() throws -> MobileRemoteSecretScope {
        try MobileRemoteSecretScope(
            accountID: "ios-native-keychain-test",
            vaultID: UUID(),
            itemID: UUID()
        )
    }
}

private enum MobileRemoteKeychainNativeTestError: Error {
    case missingExactAccessGroup
}
#endif
