import Foundation
#if canImport(Security)
import Security
#endif
import Testing
@testable import CmuxAuthRuntime

@Suite(.serialized)
struct KeychainStackTokenStoreTests {
    #if canImport(Security)
    @Test func clearingLegacyTokensPreservesSameAccountInAnotherService() async throws {
        let projectID = UUID().uuidString
        let account = "stack-auth-access-\(projectID)"
        let unrelatedService = "cmux-test-unrelated-\(UUID().uuidString)"
        let unrelatedToken = Data("unrelated-token".utf8)
        let unrelatedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: unrelatedService,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(unrelatedQuery as CFDictionary)
        defer { _ = SecItemDelete(unrelatedQuery as CFDictionary) }

        var insertion = unrelatedQuery
        insertion[kSecValueData as String] = unrelatedToken
        insertion[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlock
        try #require(SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess)

        let store = KeychainStackTokenStore(
            service: "cmux-test-current-\(UUID().uuidString)",
            legacyProjectID: projectID
        )
        await store.clearTokens()

        var lookup = unrelatedQuery
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        #expect(
            SecItemCopyMatching(lookup as CFDictionary, &result)
                == errSecSuccess
        )
        #expect(result as? Data == unrelatedToken)
    }

    /// https://github.com/manaflow-ai/cmux/issues/25628: a locked or busy
    /// Keychain is not an empty store, so session restore preserves the cached
    /// session until it can answer. A failure that never clears (a missing
    /// entitlement, a corrupt item, a failed access check) is final: treating
    /// it as unavailable would keep a session with no usable token forever.
    @Test func onlyTemporaryReadFailuresCountAsUnreadable() {
        #expect(KeychainStackTokenStore.isDefinitiveReadStatus(errSecSuccess))
        #expect(KeychainStackTokenStore.isDefinitiveReadStatus(errSecItemNotFound))
        #expect(!KeychainStackTokenStore.isDefinitiveReadStatus(errSecInteractionNotAllowed))
        #expect(!KeychainStackTokenStore.isDefinitiveReadStatus(errSecNotAvailable))
        #expect(KeychainStackTokenStore.isDefinitiveReadStatus(errSecMissingEntitlement))
        #expect(KeychainStackTokenStore.isDefinitiveReadStatus(errSecDecode))
        #expect(KeychainStackTokenStore.isDefinitiveReadStatus(errSecAuthFailed))
        #expect(KeychainStackTokenStore.isDefinitiveReadStatus(errSecParam))
    }

    @Test func fileFallbackStoreIsAlwaysReadable() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = FileStackTokenStore(directory: directory)
        await file.setTokens(accessToken: "access", refreshToken: "refresh")
        let store = FallbackTokenStore(
            primary: KeychainStackTokenStore(service: "cmux-test-empty-\(UUID().uuidString)"),
            fallback: file
        )
        // The Keychain has nothing, so the read routes to the file store.
        #expect(await store.getStoredRefreshToken() == "refresh")
        #expect(await store.isTokenStorageAvailable())
    }
    #endif
}
