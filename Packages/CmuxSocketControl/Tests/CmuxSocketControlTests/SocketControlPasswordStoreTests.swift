import Foundation
import Testing

@testable import CmuxSocketControl

@Suite struct SocketControlPasswordStoreTests {
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

        // The store trims surrounding newlines (the UI caller trims other whitespace).
        try store.savePassword("secret\n")
        #expect(try store.loadPassword() == "secret")
        #expect(store.verify(password: "secret"))

        try store.clearPassword()
        #expect(try store.loadPassword() == nil)
        #expect(!store.hasConfiguredPassword())
    }

    @Test func savingNewlineOnlyPasswordClears() throws {
        let url = tempFileURL()
        let store = SocketControlPasswordStore(environment: [:], fileURL: url)
        try store.savePassword("secret")
        #expect(try store.loadPassword() == "secret")
        // A value that is empty after newline-trimming clears the stored password.
        try store.savePassword("\n\n")
        #expect(try store.loadPassword() == nil)
    }

    @Test func keychainFallbackOnlyWhenAllowedAndCachedOnce() {
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

        // Consulted when allowed, and cached so the keychain is read once.
        #expect(store.configuredPassword(allowLazyKeychainFallback: true) == "fromkeychain")
        #expect(store.configuredPassword(allowLazyKeychainFallback: true) == "fromkeychain")
        #expect(counter.value == 1)
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
    private final class Counter: @unchecked Sendable {
        // Tests are single-threaded here; the lock keeps this safe if that ever changes.
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
    }
}
