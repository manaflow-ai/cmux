import Foundation
import Testing

@testable import CmuxSettings

@Suite(.serialized) struct SocketControlPasswordStoreTests {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pw-test-\(UUID().uuidString)")
            .appendingPathComponent("socket-control-password")
    }

    @Test func environmentPasswordTakesPriority() {
        let store = SocketControlPasswordStore(
            environment: ["CMUX_SOCKET_PASSWORD": "fromenv"],
            fileURL: tempFileURL()
        )
        #expect(store.configuredPassword() == "fromenv")
        #expect(store.hasConfiguredPassword())
        #expect(store.verify(password: "fromenv"))
        #expect(!store.verify(password: "wrong"))
    }

    @Test func saveLoadClearRoundTrip() throws {
        let url = tempFileURL()
        let store = SocketControlPasswordStore(environment: [:], fileURL: url)
        #expect(try store.loadPassword() == nil)
        #expect(!store.hasConfiguredPassword())

        // The store trims surrounding whitespace and newlines.
        try store.savePassword("  secret\n")
        #expect(try store.loadPassword() == "secret")
        #expect(store.verify(password: "secret"))

        try store.clearPassword()
        #expect(try store.loadPassword() == nil)
        #expect(!store.hasConfiguredPassword())
    }

    @Test func savingWhitespaceOnlyPasswordClears() throws {
        let url = tempFileURL()
        let store = SocketControlPasswordStore(environment: [:], fileURL: url)
        try store.savePassword("secret")
        #expect(try store.loadPassword() == "secret")
        // A value that is empty after whitespace/newline trimming clears the stored password.
        try store.savePassword("   \n\t")
        #expect(try store.loadPassword() == nil)
    }

    @Test func verifyRejectsWrongCandidate() throws {
        let store = SocketControlPasswordStore(environment: [:], fileURL: tempFileURL())
        try store.savePassword("hunter2")
        #expect(store.verify(password: "hunter2"))
        #expect(!store.verify(password: "hunter3"))
        // A length mismatch must not be accepted (constant-time comparison).
        #expect(!store.verify(password: "hunter"))
        #expect(!store.verify(password: "hunter22"))
    }

    @Test func keychainFallbackOnlyConsultedWhenAllowed() {
        let counter = Counter()
        let store = SocketControlPasswordStore(
            environment: [:],
            fileURL: tempFileURL(),
            loadKeychainPassword: {
                counter.increment()
                return "fromkeychain"
            },
            deleteKeychainPassword: { true }
        )
        // Not consulted unless explicitly allowed.
        #expect(store.configuredPassword(allowLazyKeychainFallback: false) == nil)
        #expect(counter.value == 0)

        // Consulted only when allowed. The store holds no cache (it stays free of
        // shared mutable state), so each fallback-allowed read consults the keychain.
        #expect(store.configuredPassword(allowLazyKeychainFallback: true) == "fromkeychain")
        #expect(store.configuredPassword(allowLazyKeychainFallback: true) == "fromkeychain")
        #expect(counter.value == 2)
    }

    @Test func migrateMovesKeychainPasswordIntoFileOnce() throws {
        let url = tempFileURL()
        let deleted = Counter()
        let defaults = UserDefaults(suiteName: "cmux-pw-test-\(UUID().uuidString)")!
        let store = SocketControlPasswordStore(
            environment: [:],
            fileURL: url,
            loadKeychainPassword: { "legacy" },
            deleteKeychainPassword: {
                deleted.increment()
                return true
            }
        )

        store.migrateLegacyKeychainPasswordIfNeeded(defaults: defaults)
        #expect(try store.loadPassword() == "legacy")
        #expect(deleted.value == 1)

        // Second run is a no-op (migration version recorded).
        store.migrateLegacyKeychainPasswordIfNeeded(defaults: defaults)
        #expect(deleted.value == 1)
    }

    /// Reference-typed counter so the `@Sendable` keychain closures can record call counts.
    ///
    /// The keychain closures run inline and synchronously on the test thread while
    /// the store resolves a password; there is no concurrency, and the `.serialized`
    /// suite keeps it that way, so no synchronization primitive is needed.
    private final class Counter: @unchecked Sendable {
        // Mutated only from the single test thread (see the type doc comment).
        private nonisolated(unsafe) var count = 0
        var value: Int { count }
        func increment() { count += 1 }
    }
}
