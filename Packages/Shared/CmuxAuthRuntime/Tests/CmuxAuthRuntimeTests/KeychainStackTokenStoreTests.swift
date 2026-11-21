import Foundation
#if canImport(Security)
import Security
#endif
import Testing
@testable import CmuxAuthRuntime

@Suite(.serialized)
struct KeychainStackTokenStoreTests {
    /// An existing credentials file that cannot be read is not an empty
    /// store, and the failed read is retried rather than cached.
    @Test func unreadableCredentialsFileIsUnavailableAndRetried() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = directory.appendingPathComponent("credentials.json")
        // A directory at the file's path makes every read fail.
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        let file = FileStackTokenStore(directory: directory)

        let failed = await file.readStoredTokens()
        #expect(failed.refreshToken == nil)
        #expect(!failed.isAvailable)

        try FileManager.default.removeItem(at: credentials)
        try Data(#"{"accessToken":"access","refreshToken":"refresh"}"#.utf8).write(to: credentials)
        let recovered = await file.readStoredTokens()
        #expect(recovered.refreshToken == "refresh")
        #expect(recovered.isAvailable)
    }

    /// An undecodable file never heals by retrying, so it reads as an empty,
    /// available store and the user can sign in again.
    @Test func undecodableCredentialsFileReadsAsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("credentials.json"))

        let read = await FileStackTokenStore(directory: directory).readStoredTokens()
        #expect(read.refreshToken == nil)
        #expect(read.isAvailable)
    }

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

    /// A locked Keychain is not a miss: its empty read must not return a
    /// stale file snapshot, or switch later reads to the file store.
    @Test func lockedKeychainDoesNotPromoteFileSnapshot() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = FileStackTokenStore(directory: directory)
        await file.setTokens(accessToken: "stale-access", refreshToken: "stale-refresh")
        let store = FallbackTokenStore(
            primary: KeychainStackTokenStore(
                service: "cmux-test-locked-\(UUID().uuidString)",
                copyMatching: { _ in (errSecInteractionNotAllowed, nil) }
            ),
            fallback: file
        )

        for _ in 0..<2 {
            let read = await store.readStoredTokens()
            #expect(read.accessToken == nil)
            #expect(read.refreshToken == nil)
            #expect(!read.isAvailable)
        }
    }

    /// The SDK's refresh path reads one token at a time and clears through
    /// compare-and-set. Neither may fall through to a stale file token while
    /// the Keychain is locked, or the process keeps reading and writing the
    /// file after the Keychain unlocks.
    @Test func lockedKeychainSingleTokenReadsAndCompareDoNotPromoteFileSnapshot() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = FileStackTokenStore(directory: directory)
        await file.setTokens(accessToken: "stale-access", refreshToken: "stale-refresh")
        let store = FallbackTokenStore(
            primary: KeychainStackTokenStore(
                service: "cmux-test-locked-\(UUID().uuidString)",
                copyMatching: { _ in (errSecInteractionNotAllowed, nil) }
            ),
            fallback: file
        )

        #expect(await store.getStoredAccessToken() == nil)
        #expect(await store.getStoredRefreshToken() == nil)
        await store.compareAndSet(
            compareRefreshToken: "stale-refresh",
            newRefreshToken: "rotated-refresh",
            newAccessToken: "rotated-access"
        )

        // Still routed to the Keychain: the file snapshot was neither
        // promoted nor rewritten.
        #expect(!(await store.readStoredTokens()).isAvailable)
        #expect(await file.getStoredRefreshToken() == "stale-refresh")
    }
    #endif
}
