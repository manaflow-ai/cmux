import Foundation
import Testing

@testable import CmuxSettings

@Suite(.serialized) struct SocketControlPasswordGenerationMigrationTests {
    @Test func passwordModeWithoutASecretGeneratesOne() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }

        let migration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: { "generated-secret" }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .password) == .generated)
        #expect(try fixture.store.loadPassword() == "generated-secret")
        #expect(fixture.defaults.integer(forKey: SocketControlPasswordMigration.migrationDefaultsKey)
            == SocketControlPasswordMigration.migrationVersion)
    }

    @Test func configuredSecretIsPreserved() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try fixture.store.savePassword("existing-secret")

        let migration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: { "must-not-be-used" }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .password) == .alreadyConfigured)
        #expect(try fixture.store.loadPassword() == "existing-secret")
        #expect(fixture.defaults.integer(forKey: SocketControlPasswordMigration.migrationDefaultsKey)
            == SocketControlPasswordMigration.migrationVersion)
    }

    @Test func nonPasswordModeDoesNotCreateASecret() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }

        let migration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: { "must-not-be-used" }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .automation) == .notNeeded)
        #expect(try fixture.store.loadPassword() == nil)
        #expect(fixture.defaults.object(forKey: SocketControlPasswordMigration.migrationDefaultsKey) == nil)
    }

    @Test func generationIsOneTime() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let generated = Counter()
        let migration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: {
                generated.increment()
                return "generated-secret"
            }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .password) == .generated)
        #expect(migration.migrateIfNeeded(configuredMode: .password) == .alreadyMigrated)
        #expect(generated.value == 1)
        #expect(try fixture.store.loadPassword() == "generated-secret")
    }

    @Test func anIntentionalClearAfterMigrationIsNotReplaced() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let generated = Counter()
        let migration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: {
                generated.increment()
                return "generated-secret"
            }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .password) == .generated)
        try fixture.store.clearPassword()
        #expect(migration.migrateIfNeeded(configuredMode: .password) == .alreadyMigrated)
        #expect(generated.value == 1)
        #expect(try fixture.store.loadPassword() == nil)
    }

    @Test func failedPersistenceLeavesMigrationRetryable() throws {
        let fixture = makeFixture(blockingParent: true)
        defer { fixture.cleanup() }

        let migration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: { "generated-secret" }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .password) == .failed)
        #expect(fixture.defaults.object(forKey: SocketControlPasswordMigration.migrationDefaultsKey) == nil)
    }

    private func makeFixture(blockingParent: Bool = false) -> Fixture {
        let suiteName = "cmux-socket-password-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let parent: URL
        if blockingParent {
            parent = directory.appendingPathComponent("blocked", isDirectory: false)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try? Data("not-a-directory".utf8).write(to: parent)
        } else {
            parent = directory
        }
        let passwordURL = parent.appendingPathComponent(
            SocketControlPasswordStore.fileName,
            isDirectory: false
        )
        let store = SocketControlPasswordStore(
            environment: [:],
            fileURL: passwordURL
        )
        return Fixture(
            defaults: defaults,
            store: store,
            cleanup: {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
        )
    }

    private struct Fixture {
        let defaults: UserDefaults
        let store: SocketControlPasswordStore
        let cleanup: () -> Void
    }

    private final class Counter: @unchecked Sendable {
        private nonisolated(unsafe) var count = 0
        var value: Int { count }
        func increment() { count += 1 }
    }
}
