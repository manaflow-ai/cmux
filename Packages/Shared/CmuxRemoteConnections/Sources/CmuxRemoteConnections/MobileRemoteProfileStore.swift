public import CryptoKit
public import Foundation
import SQLite3

/// An encrypted local profile repository scoped to one account and vault.
///
/// Addresses, usernames, environment values, and labels are encrypted before
/// SQLite receives them. Opaque IDs, revisions, and row counts remain visible.
/// This repository does not implement cross-device synchronization or protect
/// against restoring the entire database and key to an older state.
///
/// Construct one owner for a vault and inject it into consumers. The parent
/// directory must already exist inside the application's private container.
public actor MobileRemoteProfileStore {
    /// Bound retained records, including authenticated deletion records.
    public static let maximumRecordCount = 1_024
    /// Individual profile metadata limit; credentials and files live separately.
    public static let maximumProfileBytes = 64 * 1_024
    /// Aggregate encrypted profile budget for one local vault.
    public static let maximumVaultBytes = 8 * 1_024 * 1_024

    // All operations are actor-isolated; deinit is the sole nonisolated access.
    // FULLMUTEX additionally protects SQLite's native handle.
    private nonisolated(unsafe) let db: OpaquePointer
    private let accountID: String
    private let vaultID: UUID
    private let keyEpoch: Int64
    private let scopeID: String
    private var key: SymmetricKey?
    private let cipher = MobileRemoteVaultCipher()

    /// Opens a local database without falling back to an unencrypted store.
    ///
    /// - Parameters:
    ///   - databaseURL: File in a pre-created private application directory.
    ///   - accountID: Authenticated cmux account identifier. Anonymous or
    ///     installation-local owners are not supported by the product contract.
    ///   - vaultID: Stable vault identity.
    ///   - keyEpoch: Positive encryption-key generation.
    ///   - key: A 256-bit vault key obtained by the caller after unlocking.
    /// - Throws: Context-validation, key-size, or database errors.
    public init(
        databaseURL: URL,
        accountID: String,
        vaultID: UUID,
        keyEpoch: Int64 = 1,
        key: SymmetricKey
    ) throws {
        _ = try MobileRemoteVaultContext(
            accountID: accountID, vaultID: vaultID, recordID: vaultID,
            kind: .preferences, keyEpoch: keyEpoch, revision: 1
        )
        guard key.bitCount == 256 else { throw MobileRemoteVaultError.invalidKeySize }
        self.accountID = accountID
        self.vaultID = vaultID
        self.keyEpoch = keyEpoch
        let scope = Data("\(accountID.utf8.count):\(accountID)\(vaultID.uuidString.lowercased())".utf8)
        self.scopeID = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        self.key = key
        self.db = try Self.open(databaseURL)
    }

    deinit { sqlite3_close_v2(db) }

    /// Releases the store's key reference and denies subsequent operations.
    ///
    /// Callers must separately clear decrypted UI state and close live sessions.
    /// Swift value copies are not guaranteed to be zeroized by this operation.
    public func lock() { key = nil }

    /// Unlocks only after validating the candidate against existing vault data.
    ///
    /// - Parameter candidate: Key retrieved through the local credential policy.
    /// - Throws: Authentication or database errors; a rejected key leaves the
    ///   store locked rather than replacing the previous key.
    public func unlock(using candidate: SymmetricKey) throws {
        key = nil
        try Task.checkCancellation()
        guard candidate.bitCount == 256 else { throw MobileRemoteVaultError.invalidKeySize }
        try transaction { try verifyVault(using: candidate, createIfMissing: false) }
        try Task.checkCancellation()
        key = candidate
    }

    /// Reads one profile only after authenticating its owner and record context.
    ///
    /// - Parameter id: Opaque profile identifier.
    /// - Returns: The profile, or nil when absent or authentically deleted.
    /// - Throws: Locked, database, decoding, or authentication errors.
    public func profile(id: UUID) throws -> MobileRemoteProfile? {
        try Task.checkCancellation()
        let key = try unlockedKey()
        return try transaction {
            try verifyVault(using: key, createIfMissing: false)
            return try readRow(id: id, using: key)?.profile
        }
    }

    /// Returns live profiles after authenticating every scoped row.
    ///
    /// Even tombstones are authenticated so a flipped deletion flag cannot hide
    /// a live row silently. Row removal and whole-file rollback require the
    /// separate sync/membership integrity layer.
    ///
    /// - Returns: Profiles ordered by their opaque identifiers.
    /// - Throws: Locked, capacity, database, or authentication errors.
    public func profiles() throws -> [MobileRemoteProfile] {
        try Task.checkCancellation()
        let key = try unlockedKey()
        return try transaction {
            try verifyVault(using: key, createIfMissing: false)
            let statement = try prepare("""
                SELECT profile_id, revision, deleted, ciphertext
                FROM remote_profiles WHERE scope_id = ? ORDER BY profile_id
                LIMIT \(Self.maximumRecordCount + 1)
                """)
            defer { sqlite3_finalize(statement) }
            try bind(scopeID, to: statement, at: 1)
            var profiles: [MobileRemoteProfile] = []
            var seen = 0
            var totalBytes = 0
            while try step(statement) == SQLITE_ROW {
                try Task.checkCancellation()
                seen += 1
                totalBytes += Int(sqlite3_column_bytes(statement, 3))
                guard seen <= Self.maximumRecordCount, totalBytes <= Self.maximumVaultBytes else {
                    throw MobileRemoteProfileStoreError.capacityExceeded
                }
                guard let text = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: text)) else {
                    throw MobileRemoteProfileStoreError.corruptRecord
                }
                if let profile = try decodeRow(statement, id: id, offset: 1, using: key).profile {
                    profiles.append(profile)
                }
            }
            return profiles
        }
    }

    /// Atomically saves a validated profile after authenticating prior state.
    ///
    /// - Parameter profile: Immutable profile whose secret values live elsewhere.
    /// - Throws: Locked, validation, capacity, database, or authentication errors.
    public func save(_ profile: MobileRemoteProfile) throws {
        try Task.checkCancellation()
        try profile.validate()
        let key = try unlockedKey()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(profile)
        guard payload.count <= Self.maximumProfileBytes else {
            throw MobileRemoteProfileStoreError.capacityExceeded
        }
        try write(id: profile.id, payload: payload, deleted: false, using: key)
    }

    /// Persists an authenticated deletion rather than a plaintext absence flag.
    ///
    /// This does not delete a shared SSH credential or terminate remote work.
    ///
    /// - Parameter id: Profile to delete.
    /// - Throws: Locked, capacity, database, or authentication errors.
    public func remove(id: UUID) throws {
        try Task.checkCancellation()
        try write(id: id, payload: Data(), deleted: true, using: unlockedKey())
    }

    private func unlockedKey() throws -> SymmetricKey {
        guard let key else { throw MobileRemoteProfileStoreError.locked }
        return key
    }

    private func write(id: UUID, payload: Data, deleted: Bool, using key: SymmetricKey) throws {
        try transaction {
            try verifyVault(using: key, createIfMissing: true)
            let previous = try readRow(id: id, using: key)
            if previous == nil { try enforceCapacity() }
            let (revision, overflow) = (previous?.revision ?? 0).addingReportingOverflow(1)
            guard !overflow else { throw MobileRemoteProfileStoreError.corruptRecord }
            let context = try context(id: id, revision: revision, deleted: deleted)
            let encrypted = try cipher.encrypt(payload, context: context, key: key)
            try enforceByteCapacity(replacing: id, with: encrypted.sealedBox.count)
            let statement = try prepare("""
                INSERT INTO remote_profiles(scope_id, profile_id, revision, deleted, ciphertext)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(scope_id, profile_id) DO UPDATE SET
                    revision=excluded.revision, deleted=excluded.deleted, ciphertext=excluded.ciphertext
                """)
            defer { sqlite3_finalize(statement) }
            try bind(scopeID, to: statement, at: 1)
            try bind(id.uuidString.lowercased(), to: statement, at: 2)
            try check(sqlite3_bind_int64(statement, 3, revision))
            try check(sqlite3_bind_int(statement, 4, deleted ? 1 : 0))
            try bind(encrypted.sealedBox, to: statement, at: 5)
            _ = try step(statement)
        }
    }

    private func verifyVault(using key: SymmetricKey, createIfMissing: Bool) throws {
        let statement = try prepare("SELECT key_epoch, key_check FROM remote_profile_vaults WHERE scope_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(scopeID, to: statement, at: 1)
        let vaultContext = try MobileRemoteVaultContext(
            accountID: accountID, vaultID: vaultID, recordID: vaultID,
            kind: .preferences, keyEpoch: keyEpoch, revision: 1
        )
        if try step(statement) == SQLITE_ROW {
            guard sqlite3_column_int64(statement, 0) == keyEpoch else {
                throw MobileRemoteProfileStoreError.keyEpochMismatch
            }
            let check = try envelope(statement, column: 1)
            guard try cipher.decrypt(check, context: vaultContext, key: key).isEmpty else {
                throw MobileRemoteProfileStoreError.corruptRecord
            }
            return
        }
        // Missing key custody must not cause existing encrypted profiles to be
        // silently adopted under a fresh key.
        let count = try rowCount()
        guard count == 0 else { throw MobileRemoteProfileStoreError.corruptRecord }
        guard createIfMissing else { return }
        let sealed = try cipher.encrypt(Data(), context: vaultContext, key: key)
        let insert = try prepare("INSERT INTO remote_profile_vaults(scope_id, key_epoch, key_check) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(insert) }
        try bind(scopeID, to: insert, at: 1)
        try check(sqlite3_bind_int64(insert, 2, keyEpoch))
        try bind(sealed.sealedBox, to: insert, at: 3)
        _ = try step(insert)
    }

    private func readRow(id: UUID, using key: SymmetricKey) throws -> (revision: Int64, profile: MobileRemoteProfile?)? {
        let statement = try prepare("""
            SELECT revision, deleted, ciphertext FROM remote_profiles
            WHERE scope_id = ? AND profile_id = ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(scopeID, to: statement, at: 1)
        try bind(id.uuidString.lowercased(), to: statement, at: 2)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return try decodeRow(statement, id: id, offset: 0, using: key)
    }

    private func decodeRow(
        _ statement: OpaquePointer, id: UUID, offset: Int32, using key: SymmetricKey
    ) throws -> (revision: Int64, profile: MobileRemoteProfile?) {
        let revision = sqlite3_column_int64(statement, offset)
        let deletion = sqlite3_column_int(statement, offset + 1)
        guard revision > 0, deletion == 0 || deletion == 1 else {
            throw MobileRemoteProfileStoreError.corruptRecord
        }
        let payload = try cipher.decrypt(
            envelope(statement, column: offset + 2),
            context: context(id: id, revision: revision, deleted: deletion == 1),
            key: key
        )
        if deletion == 1 { return (revision, nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let profile: MobileRemoteProfile
        do { profile = try decoder.decode(MobileRemoteProfile.self, from: payload) }
        catch { throw MobileRemoteProfileStoreError.corruptRecord }
        guard profile.id == id else { throw MobileRemoteProfileStoreError.corruptRecord }
        return (revision, profile)
    }

    private func context(id: UUID, revision: Int64, deleted: Bool) throws -> MobileRemoteVaultContext {
        try MobileRemoteVaultContext(
            accountID: accountID, vaultID: vaultID, recordID: id, kind: .profile,
            keyEpoch: keyEpoch, revision: revision, deleted: deleted
        )
    }

    private func envelope(_ statement: OpaquePointer, column: Int32) throws -> MobileRemoteVaultEnvelope {
        let size = Int(sqlite3_column_bytes(statement, column))
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              size >= 28, size <= Self.maximumProfileBytes + 28,
              let bytes = sqlite3_column_blob(statement, column) else {
            throw MobileRemoteProfileStoreError.corruptRecord
        }
        return try MobileRemoteVaultEnvelope(sealedBox: Data(bytes: bytes, count: size))
    }

    private func rowCount() throws -> Int64 {
        let statement = try prepare("SELECT COUNT(*) FROM remote_profiles WHERE scope_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(scopeID, to: statement, at: 1)
        guard try step(statement) == SQLITE_ROW else { throw MobileRemoteProfileStoreError.corruptRecord }
        return sqlite3_column_int64(statement, 0)
    }

    private func enforceCapacity() throws {
        guard try rowCount() < Self.maximumRecordCount else {
            throw MobileRemoteProfileStoreError.capacityExceeded
        }
    }

    private func enforceByteCapacity(replacing id: UUID, with bytes: Int) throws {
        let statement = try prepare("""
            SELECT COALESCE(SUM(length(ciphertext)), 0) FROM remote_profiles
            WHERE scope_id = ? AND profile_id != ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(scopeID, to: statement, at: 1)
        try bind(id.uuidString.lowercased(), to: statement, at: 2)
        guard try step(statement) == SQLITE_ROW,
              sqlite3_column_int64(statement, 0) <= Int64(Self.maximumVaultBytes - bytes) else {
            throw MobileRemoteProfileStoreError.capacityExceeded
        }
    }

    private func transaction<T>(_ action: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try action()
            try Task.checkCancellation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw MobileRemoteProfileStoreError.corruptRecord }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        try check(value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        })
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        try check(value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count),
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        })
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw MobileRemoteProfileStoreError.database(code) }
    }

    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw MobileRemoteProfileStoreError.database(result)
        }
        return result
    }

    private nonisolated static func open(_ url: URL) throws -> OpaquePointer {
        guard url.isFileURL else { throw MobileRemoteProfileStoreError.corruptRecord }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw MobileRemoteProfileStoreError.database(result)
        }
        do {
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(Self.maximumProfileBytes * 2))
            guard sqlite3_busy_timeout(handle, 1_000) == SQLITE_OK else {
                throw MobileRemoteProfileStoreError.database(SQLITE_ERROR)
            }
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw MobileRemoteProfileStoreError.database(sqlite3_errcode(handle))
            }
            // Schema changes are transactional. Refuse unknown versions before
            // touching data rather than reset a newer vault.
            var versionStatement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
                  let versionStatement else {
                throw MobileRemoteProfileStoreError.database(SQLITE_ERROR)
            }
            let step = sqlite3_step(versionStatement)
            let version = sqlite3_column_int(versionStatement, 0)
            sqlite3_finalize(versionStatement)
            guard step == SQLITE_ROW, version == 0 || version == 1 else {
                throw MobileRemoteProfileStoreError.unsupportedSchema
            }
            if version == 0 {
                var countStatement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &countStatement, nil) == SQLITE_OK,
                      let countStatement else {
                    throw MobileRemoteProfileStoreError.database(SQLITE_ERROR)
                }
                let countStep = sqlite3_step(countStatement)
                let count = sqlite3_column_int64(countStatement, 0)
                sqlite3_finalize(countStatement)
                guard countStep == SQLITE_ROW, count == 0 else {
                    throw MobileRemoteProfileStoreError.unsupportedSchema
                }
            }
            let schema = version == 0 ? """
                CREATE TABLE IF NOT EXISTS remote_profile_vaults(
                    scope_id TEXT PRIMARY KEY, key_epoch INTEGER NOT NULL,
                    key_check BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS remote_profiles(
                    scope_id TEXT NOT NULL, profile_id TEXT NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
                    ciphertext BLOB NOT NULL,
                    PRIMARY KEY(scope_id, profile_id));
                PRAGMA user_version = 1;
                """ : """
                SELECT scope_id, key_epoch, key_check FROM remote_profile_vaults LIMIT 0;
                SELECT scope_id, profile_id, revision, deleted, ciphertext FROM remote_profiles LIMIT 0;
                """
            guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
                throw MobileRemoteProfileStoreError.database(sqlite3_errcode(handle))
            }
            guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw MobileRemoteProfileStoreError.database(sqlite3_errcode(handle))
            }
            return handle
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(handle)
            throw error
        }
    }
}
