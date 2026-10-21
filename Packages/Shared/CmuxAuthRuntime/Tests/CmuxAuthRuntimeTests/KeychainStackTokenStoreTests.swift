import Foundation
#if canImport(Security)
import Security
#endif
import Testing
@testable import CmuxAuthRuntime

@Suite(.serialized)
struct KeychainStackTokenStoreTests {
    #if canImport(Security)
    /// Whether this process can write the login keychain. A CI step on a
    /// host with no GUI login session gets -60008 (errAuthorizationInternal)
    /// from every SecItemAdd, so the test runs only where a keychain exists
    /// (developer Macs, the GUI build host); it exercises the real keychain
    /// query scope, which an in-memory double would not.
    static let keychainWritable: Bool = writable {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cmux-test-probe-\(UUID().uuidString)",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("probe".utf8),
            // The same attributes as the test's insert, and never a prompt:
            // a locked keychain without a GUI session fails instead of
            // waiting for a password dialog nobody can answer.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let keys: Set<String> = [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String]
        let status = SecItemAdd(query as CFDictionary, nil)
        _ = SecItemDelete(query.filter { keys.contains($0.key) } as CFDictionary)
        return status
    }

    /// Whether `add` (a probe write and its cleanup) succeeds within `limit`. It runs on its
    /// own thread: a write that never returns (a locked keychain waiting in securityd) is left
    /// there, and the keychain counts as not writable.
    static func writable(within limit: DispatchTimeInterval = .seconds(5),
                         add: @escaping @Sendable () -> OSStatus) -> Bool {
        final class Outcome: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var status: OSStatus = errSecNotAvailable
        }
        let outcome = Outcome()
        Thread.detachNewThread {
            outcome.status = add()
            outcome.done.signal()
        }
        // The semaphore orders the write of `status` before this read.
        guard outcome.done.wait(timeout: .now() + limit) == .success else { return false }
        return outcome.status == errSecSuccess
    }

    /// cx-4av5t: on some fleet hosts the probe's SecItemAdd never returned (a locked login
    /// keychain waits in securityd), and the suite hung 300 s before any test ran. A probe
    /// write that never answers counts as no writable keychain.
    @Test(.timeLimit(.minutes(1)))
    func aKeychainThatNeverAnswersCountsAsNotWritable() {
        let never = DispatchSemaphore(value: 0)
        #expect(!Self.writable { never.wait(); return errSecSuccess })
    }

    @Test
    func tokenItemsUseDeviceOnlyProtection() {
        #expect(
            KeychainStackTokenStore.keychainAccessibility
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @Test(.enabled(if: keychainWritable, "no writable keychain (no GUI login session)"))
    func clearingLegacyTokensPreservesSameAccountInAnotherService() async throws {
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
    #endif
}
