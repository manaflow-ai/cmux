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

    /// https://github.com/manaflow-ai/cmux/issues/25628: a Keychain read that
    /// fails for a moment is not an empty store, so session restore must not
    /// sign out on it; a permanent failure must still reach sign-in.
    @Test func onlyTemporaryReadFailuresCountAsUnreadable() {
        #expect(KeychainStackTokenStore.isTemporaryReadFailure(errSecInteractionNotAllowed))
        #expect(KeychainStackTokenStore.isTemporaryReadFailure(errSecNotAvailable))
        #expect(!KeychainStackTokenStore.isTemporaryReadFailure(errSecSuccess))
        #expect(!KeychainStackTokenStore.isTemporaryReadFailure(errSecItemNotFound))
        #expect(!KeychainStackTokenStore.isTemporaryReadFailure(errSecMissingEntitlement))
        #expect(!KeychainStackTokenStore.isTemporaryReadFailure(errSecDecode))
        #expect(!KeychainStackTokenStore.isTemporaryReadFailure(errSecParam))
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
