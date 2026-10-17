import Foundation
#if canImport(Security)
import Security
#endif
import Testing
@testable import CmuxAuthRuntime

@Suite(.serialized)
struct KeychainStackTokenStoreTests {
    @Test func accessGroupSelectionMatchesExactBundleIdentity() {
        let groups = [
            "7WLXT3NR37.com.cmuxterm.app",
            "7WLXT3NR37.com.cmuxterm.app.nightly",
            "7WLXT3NR37.com.cmuxterm.app.nightly.preview",
        ]

        #expect(
            KeychainStackTokenStore.accessGroup(
                from: groups,
                bundleIdentifier: "com.cmuxterm.app.nightly"
            ) == "7WLXT3NR37.com.cmuxterm.app.nightly"
        )
        #expect(
            KeychainStackTokenStore.accessGroup(
                from: groups,
                bundleIdentifier: "com.cmuxterm.app"
            ) == "7WLXT3NR37.com.cmuxterm.app"
        )
        #expect(
            KeychainStackTokenStore.accessGroup(
                from: groups,
                bundleIdentifier: "com.cmuxterm.app.rc"
            ) == nil
        )
    }

    #if canImport(Security)
    private final class FailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [KeychainStackTokenStoreFailure] = []

        func append(_ value: KeychainStackTokenStoreFailure) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [KeychainStackTokenStoreFailure] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    @Test func readableEmptyKeychainReportsAvailable() async {
        let recorder = FailureRecorder()
        let store = KeychainStackTokenStore(
            service: "cmux-test-availability-\(UUID().uuidString)",
            onFailure: { recorder.append($0) }
        )

        // Hosted SwiftPM workers do not expose a process keychain. Preserve
        // the real-keychain assertion on signed/interactive hosts while
        // allowing that environment to exercise the remaining diagnostics.
        guard await store.isStorageAvailable() else { return }
        #expect(recorder.snapshot().isEmpty)
    }

    @Test func missingKeychainEntitlementReportsUnavailable() async {
        let store = KeychainStackTokenStore(
            service: "cmux-test-unavailable-\(UUID().uuidString)",
            accessGroup: "com.cmux.invalid.\(UUID().uuidString)"
        )

        #expect(await store.isStorageAvailable() == false)
    }

    @Test func unusualKeychainStatusesAreReportedOncePerSignature() async {
        let recorder = FailureRecorder()
        let store = KeychainStackTokenStore(
            service: "cmux-test-diagnostics-\(UUID().uuidString)",
            accessGroup: "com.cmux.invalid.\(UUID().uuidString)",
            onFailure: { recorder.append($0) },
            now: { Date(timeIntervalSince1970: 100) },
            failureReportInterval: 300
        )

        #expect(await store.isStorageAvailable() == false)
        #expect(await store.isStorageAvailable() == false)

        let failures = recorder.snapshot()
        #expect(failures.count == 2)
        #expect(failures.allSatisfy { $0.operation == .availabilityRead })
        #expect(Set(failures.map(\.accountRole)) == [.access, .refresh])
        #expect(failures.allSatisfy { $0.hasAccessGroup })
        #expect(failures.allSatisfy { $0.status != 0 })
    }

    @Test func writeStatusesAreReportedWithoutCredentialContents() async {
        let recorder = FailureRecorder()
        let store = KeychainStackTokenStore(
            service: "cmux-test-write-diagnostics-\(UUID().uuidString)",
            accessGroup: "com.cmux.invalid.\(UUID().uuidString)",
            onFailure: { recorder.append($0) },
            now: { Date(timeIntervalSince1970: 100) },
            failureReportInterval: 300
        )

        #expect(await store.trySetTokens(
            accessToken: "access-secret-that-must-not-be-reported",
            refreshToken: "refresh-secret-that-must-not-be-reported"
        ) == false)

        let failures = recorder.snapshot()
        #expect(failures.count == 4)
        #expect(failures.contains { $0.operation == .update && $0.accountRole == .access })
        #expect(failures.contains { $0.operation == .add && $0.accountRole == .access })
        #expect(failures.contains { $0.operation == .update && $0.accountRole == .refresh })
        #expect(failures.contains { $0.operation == .add && $0.accountRole == .refresh })
    }

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
        // A headless hosted worker may reject all Security.framework writes;
        // this test only has meaning when the worker exposes a writable
        // keychain.
        guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { return }

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
