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
            generatePassword: {
                Issue.record("Password generator ran with an existing durable secret")
                return "unexpected-secret"
            }
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
            generatePassword: {
                Issue.record("Password generator ran outside password mode")
                return "unexpected-secret"
            }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .automation) == .notNeeded)
        #expect(try fixture.store.loadPassword() == nil)
        #expect(fixture.defaults.object(forKey: SocketControlPasswordMigration.migrationDefaultsKey) == nil)
    }

    @Test func generationIsOneTime() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let migration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: { "generated-secret" }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .password) == .generated)
        let repeatedMigration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: {
                Issue.record("Password generator ran after migration completed")
                return "unexpected-secret"
            }
        )
        #expect(
            repeatedMigration.migrateIfNeeded(configuredMode: .password) == .alreadyMigrated
        )
        #expect(try fixture.store.loadPassword() == "generated-secret")
    }

    @Test func anIntentionalClearAfterMigrationIsNotReplaced() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let migration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: { "generated-secret" }
        )

        #expect(migration.migrateIfNeeded(configuredMode: .password) == .generated)
        try fixture.store.clearPassword()
        let repeatedMigration = SocketControlPasswordMigration(
            defaults: fixture.defaults,
            passwordStore: fixture.store,
            generatePassword: {
                Issue.record("Password generator ran after an intentional clear")
                return "unexpected-secret"
            }
        )
        #expect(
            repeatedMigration.migrateIfNeeded(configuredMode: .password) == .alreadyMigrated
        )
        #expect(try fixture.store.loadPassword() == nil)
    }

    @Test func environmentOnlySecretDoesNotCompleteDurableMigration() throws {
        let fixture = makeFixture(environment: [
            SocketControlSettings.socketPasswordEnvKey: "transient-secret",
        ])
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

    private func makeFixture(
        blockingParent: Bool = false,
        environment: [String: String] = [:]
    ) -> Fixture {
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
            environment: environment,
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
}
