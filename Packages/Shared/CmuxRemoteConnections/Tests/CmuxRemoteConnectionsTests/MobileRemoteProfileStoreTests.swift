import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteProfileStoreTests {
    @Test func savesUpdatesReopensAndDeletesWithoutPlaintextOnDisk() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let key = SymmetricKey(size: .bits256)
        let store = try fixture.store(key: key)
        let id = UUID()
        try await store.save(fixture.profile(id: id, host: "private-first.example"))
        try await store.save(fixture.profile(id: id, host: "private-updated.example"))
        let reopened = try fixture.store(key: key)
        #expect(try await reopened.profile(id: id)?.host == "private-updated.example")
        #expect(try await reopened.profiles().count == 1)
        let bytes = try Data(contentsOf: fixture.url)
        for privateText in ["private-first.example", "private-updated.example", "private-user", "private-owner"] {
            #expect(bytes.range(of: Data(privateText.utf8)) == nil)
        }
        try await reopened.remove(id: id)
        #expect(try await store.profile(id: id) == nil)
        #expect(try await store.profiles().isEmpty)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM remote_profiles WHERE deleted=1") == 1)
    }

    @Test func accountAndVaultScopesNeverReadOrRemoveEachOthersProfiles() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let key = SymmetricKey(size: .bits256)
        let a = try fixture.store(key: key)
        let b = try fixture.store(account: "other-owner", key: key)
        let c = try fixture.store(vault: UUID(), key: key)
        let profile = try fixture.profile()
        try await a.save(profile)
        #expect(try await b.profiles().isEmpty)
        #expect(try await c.profile(id: profile.id) == nil)
        try await b.remove(id: profile.id)
        #expect(try await a.profile(id: profile.id) == profile)
    }

    @Test func wrongKeyCannotReadOverwriteOrAddToAnExistingVault() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let key = SymmetricKey(size: .bits256)
        let good = try fixture.store(key: key)
        let profile = try fixture.profile()
        try await good.save(profile)
        let wrong = try fixture.store(key: SymmetricKey(size: .bits256))
        await #expect(throws: MobileRemoteVaultError.authenticationFailed) {
            try await wrong.profiles()
        }
        await #expect(throws: MobileRemoteVaultError.authenticationFailed) {
            try await wrong.save(profile)
        }
        await #expect(throws: MobileRemoteVaultError.authenticationFailed) {
            try await wrong.save(fixture.profile())
        }
        #expect(try await good.profiles() == [profile])
    }

    @Test func lockedStoreRequiresSuccessfulKeyVerification() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let key = SymmetricKey(size: .bits256)
        let store = try fixture.store(key: key)
        let profile = try fixture.profile()
        try await store.save(profile)
        await store.lock()
        await #expect(throws: MobileRemoteProfileStoreError.locked) { try await store.profiles() }
        await #expect(throws: MobileRemoteProfileStoreError.locked) { try await store.save(profile) }
        await #expect(throws: MobileRemoteVaultError.authenticationFailed) {
            try await store.unlock(using: SymmetricKey(size: .bits256))
        }
        await #expect(throws: MobileRemoteProfileStoreError.locked) { try await store.profiles() }
        try await store.unlock(using: key)
        #expect(try await store.profiles() == [profile])
    }

    @Test func swappedCiphertextAndForgedDeletionFailAuthentication() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.store(key: SymmetricKey(size: .bits256))
        let a = try fixture.profile()
        let b = try fixture.profile()
        try await store.save(a)
        try await store.save(b)
        try fixture.exec("""
            UPDATE remote_profiles SET ciphertext=(
                SELECT ciphertext FROM remote_profiles WHERE profile_id='\(a.id.uuidString.lowercased())'
            ) WHERE profile_id='\(b.id.uuidString.lowercased())'
            """)
        await #expect(throws: MobileRemoteVaultError.authenticationFailed) {
            try await store.profile(id: b.id)
        }
        try fixture.exec("UPDATE remote_profiles SET deleted=1 WHERE profile_id='\(a.id.uuidString.lowercased())'")
        // Deletion flags are verified before filtering, so this cannot appear empty.
        await #expect(throws: MobileRemoteVaultError.authenticationFailed) { try await store.profiles() }
    }

    @Test func missingKeyCheckCannotReinitializeExistingData() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.store(key: SymmetricKey(size: .bits256))
        try await store.save(fixture.profile())
        try fixture.exec("DELETE FROM remote_profile_vaults")
        await #expect(throws: MobileRemoteProfileStoreError.corruptRecord) {
            try await store.save(fixture.profile())
        }
        #expect(try fixture.scalar("SELECT COUNT(*) FROM remote_profiles") == 1)
    }

    @Test func oversizedProfileCannotReplaceCommittedData() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.store(key: SymmetricKey(size: .bits256))
        let original = try fixture.profile()
        try await store.save(original)
        let large = try MobileRemoteProfile(
            id: original.id, host: "example.com", username: "alice",
            environment: ["DATA": String(repeating: "a", count: MobileRemoteProfileStore.maximumProfileBytes)]
        )
        await #expect(throws: MobileRemoteProfileStoreError.capacityExceeded) {
            try await store.save(large)
        }
        #expect(try await store.profile(id: original.id) == original)
    }

    @Test func unknownDatabaseSchemaIsNotOverwritten() throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store(key: SymmetricKey(size: .bits256))
        try fixture.exec("PRAGMA user_version=999")
        #expect(throws: MobileRemoteProfileStoreError.unsupportedSchema) {
            try fixture.store(key: SymmetricKey(size: .bits256))
        }
        #expect(try fixture.scalar("PRAGMA user_version") == 999)
    }

    @Test func mismatchedKeyEpochIsNotASeparateEmptyVault() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let key = SymmetricKey(size: .bits256)
        let original = try fixture.store(key: key)
        try await original.save(fixture.profile())
        let wrongEpoch = try MobileRemoteProfileStore(
            databaseURL: fixture.url, accountID: "private-owner",
            vaultID: fixture.vaultID, keyEpoch: 2, key: key
        )
        await #expect(throws: MobileRemoteProfileStoreError.keyEpochMismatch) {
            try await wrongEpoch.profiles()
        }
    }

    @Test func corruptExistingSchemaIsNotRecreatedAsEmpty() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let key = SymmetricKey(size: .bits256)
        let store = try fixture.store(key: key)
        try await store.save(fixture.profile())
        try fixture.exec("DROP TABLE remote_profiles")
        #expect(throws: MobileRemoteProfileStoreError.database(SQLITE_ERROR)) {
            try fixture.store(key: key)
        }
        #expect(try fixture.scalar("SELECT COUNT(*) FROM sqlite_schema WHERE name='remote_profiles'") == 0)
    }

    @Test func doesNotAdoptAnUnrelatedUnversionedDatabase() throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        try fixture.exec("CREATE TABLE other_application(data TEXT)")
        #expect(throws: MobileRemoteProfileStoreError.unsupportedSchema) {
            try fixture.store(key: SymmetricKey(size: .bits256))
        }
        #expect(try fixture.scalar("PRAGMA user_version") == 0)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM sqlite_schema WHERE name='remote_profiles'") == 0)
    }

    @Test func simultaneousRepositoryOwnersDoNotLoseCommittedProfiles() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let key = SymmetricKey(size: .bits256)
        let a = try fixture.store(key: key)
        let b = try fixture.store(key: key)
        let profiles = try (0..<20).map { _ in try fixture.profile() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, profile) in profiles.enumerated() {
                let store = index.isMultiple(of: 2) ? a : b
                group.addTask { try await store.save(profile) }
            }
            try await group.waitForAll()
        }
        #expect(try await Set(a.profiles().map(\.id)) == Set(profiles.map(\.id)))
    }

    @Test func cancelledSaveCannotCreateAProfile() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.store(key: SymmetricKey(size: .bits256))
        let profile = try fixture.profile()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.save(profile)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.profiles().isEmpty)
    }

    @Test func failedWritePreservesPreviousCommittedProfile() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.store(key: SymmetricKey(size: .bits256))
        let original = try fixture.profile()
        try await store.save(original)
        try fixture.exec("""
            CREATE TRIGGER reject_write BEFORE UPDATE ON remote_profiles
            BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END;
            """)
        await #expect(throws: MobileRemoteProfileStoreError.database(SQLITE_CONSTRAINT)) {
            try await store.save(fixture.profile(id: original.id, host: "replacement.example"))
        }
        #expect(try await store.profile(id: original.id) == original)
        #expect(try fixture.scalar("SELECT revision FROM remote_profiles") == 1)
    }

    @Test func failedFirstWriteDoesNotLeaveAKeyMarkerWithoutItsRecord() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.store(key: SymmetricKey(size: .bits256))
        try fixture.exec("""
            CREATE TRIGGER reject_write BEFORE INSERT ON remote_profiles
            BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END;
            """)
        await #expect(throws: MobileRemoteProfileStoreError.database(SQLITE_CONSTRAINT)) {
            try await store.save(fixture.profile())
        }
        #expect(try fixture.scalar("SELECT COUNT(*) FROM remote_profile_vaults") == 0)
        #expect(try fixture.scalar("SELECT COUNT(*) FROM remote_profiles") == 0)
    }
}
