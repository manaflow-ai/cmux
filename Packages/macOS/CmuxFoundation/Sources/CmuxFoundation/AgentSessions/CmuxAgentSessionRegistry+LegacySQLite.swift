import Foundation
import SQLite3

extension CmuxAgentSessionRegistry {
    enum LegacySourceState: Equatable {
        case changed
        case imported
        case quarantined
    }

    func deleteLegacyRows(
        database: OpaquePointer,
        provider: String,
        preservingSessionRows: Bool = false
    ) throws {
        let tables = preservingSessionRows
            ? ["agent_active_slots"]
            : ["agent_sessions", "agent_active_slots"]
        for table in tables {
            let statement = try prepare(
                database,
                "DELETE FROM \(table) WHERE provider = ?1 AND writer_generation = 0"
            )
            defer { sqlite3_finalize(statement) }
            try bind(provider, to: 1, in: statement)
            try stepDone(statement, database: database, operation: "delete legacy rows")
        }
    }

    func legacySourceIsCurrent(
        database: OpaquePointer,
        provider: String,
        stamp: LegacyStamp
    ) throws -> Bool {
        try legacySourceState(database: database, provider: provider, stamp: stamp) == .imported
    }

    func legacySourceCanBeSkippedForCanonicalRebind(
        database: OpaquePointer,
        provider: String,
        stamp: LegacyStamp
    ) throws -> Bool {
        try legacySourceState(database: database, provider: provider, stamp: stamp) != .changed
    }

    func legacySourceState(
        database: OpaquePointer,
        provider: String,
        stamp: LegacyStamp
    ) throws -> LegacySourceState {
        guard let deviceID = stamp.deviceID,
            let inode = stamp.inode,
            let modifiedSeconds = stamp.modifiedSeconds,
            let modifiedNanoseconds = stamp.modifiedNanoseconds,
            let changedSeconds = stamp.changedSeconds,
            let changedNanoseconds = stamp.changedNanoseconds
        else {
            return .changed
        }
        let statement = try prepare(
            database,
            """
            SELECT size, quarantined,
                   device_id, inode,
                   modified_seconds, modified_nanoseconds,
                   changed_seconds, changed_nanoseconds
            FROM agent_legacy_sources
            WHERE provider = ?1 AND path = ?2
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(stamp.path, to: 2, in: statement)
        guard try stepRow(statement, database: database, operation: "read legacy checkpoint") else {
            return .changed
        }
        guard sqlite3_column_int64(statement, 0) == stamp.size,
              sqlite3_column_type(statement, 2) != SQLITE_NULL,
              sqlite3_column_int64(statement, 2) == deviceID,
              sqlite3_column_type(statement, 3) != SQLITE_NULL,
              sqlite3_column_int64(statement, 3) == inode,
              sqlite3_column_type(statement, 4) != SQLITE_NULL,
              sqlite3_column_int64(statement, 4) == modifiedSeconds,
              sqlite3_column_type(statement, 5) != SQLITE_NULL,
              sqlite3_column_int64(statement, 5) == modifiedNanoseconds,
              sqlite3_column_type(statement, 6) != SQLITE_NULL,
              sqlite3_column_int64(statement, 6) == changedSeconds,
              sqlite3_column_type(statement, 7) != SQLITE_NULL,
              sqlite3_column_int64(statement, 7) == changedNanoseconds else {
            return .changed
        }
        return sqlite3_column_int(statement, 1) == 0 ? .imported : .quarantined
    }

    func replaceLegacy(
        database: OpaquePointer,
        provider: String,
        stamp: LegacyStamp,
        payload: LegacyPayload
    ) throws {
        try validateHookWriteBatch(
            provider: provider,
            records: payload.records,
            activeSlots: payload.activeSlots
        )
        let previousProviderBytes = try hookProviderStorageBytes(
            database: database,
            provider: provider
        )
        // Once cmux has published a bounded compatibility projection, absence
        // from legacy JSON no longer means a canonical session was deleted.
        // Older writers see only active owners plus recent history and can
        // safely append or update generation-zero records. Active slots remain
        // a complete projection, so their removals must still propagate.
        let preservesOmittedSessions = try hookProjectionHasPublished(
            database: database,
            provider: provider
        )
        try deleteLegacyRows(
            database: database,
            provider: provider,
            preservingSessionRows: preservesOmittedSessions
        )
        for var record in payload.records {
            record.provider = provider
            record.writerGeneration = 0
            try upsert(record, database: database)
        }
        for var slot in payload.activeSlots {
            slot.provider = provider
            slot.writerGeneration = 0
            try upsert(slot, database: database)
        }
        try reconcileHookProviderStorageLimit(
            database: database,
            provider: provider,
            protectedSessionIDs: [],
            previousBytes: previousProviderBytes
        )
        try writeLegacyStamp(database: database, provider: provider, stamp: stamp)
    }

    private func hookProjectionHasPublished(
        database: OpaquePointer,
        provider: String
    ) throws -> Bool {
        let table = try prepare(
            database,
            """
            SELECT 1 FROM sqlite_master
            WHERE type = 'table' AND name = 'agent_provider_metadata'
            """
        )
        defer { sqlite3_finalize(table) }
        guard try stepRow(table, database: database, operation: "find hook projection metadata") else {
            return false
        }

        let statement = try prepare(
            database,
            """
            SELECT projected_revision > 0
            FROM agent_provider_metadata
            WHERE provider = ?1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        guard try stepRow(
            statement,
            database: database,
            operation: "read hook projection publication"
        ) else {
            return false
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    func writeLegacyStamp(
        database: OpaquePointer,
        provider: String,
        stamp: LegacyStamp,
        quarantined: Bool = false
    ) throws {
        let statement = try prepare(
            database,
            """
            INSERT INTO agent_legacy_sources (
                provider, path, size, modified_at, imported_at, quarantined,
                device_id, inode,
                modified_seconds, modified_nanoseconds,
                changed_seconds, changed_nanoseconds
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(provider, path) DO UPDATE SET
                size = excluded.size,
                modified_at = excluded.modified_at,
                imported_at = excluded.imported_at,
                quarantined = excluded.quarantined,
                device_id = excluded.device_id,
                inode = excluded.inode,
                modified_seconds = excluded.modified_seconds,
                modified_nanoseconds = excluded.modified_nanoseconds,
                changed_seconds = excluded.changed_seconds,
                changed_nanoseconds = excluded.changed_nanoseconds
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(stamp.path, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, stamp.size)
        sqlite3_bind_double(statement, 4, stamp.modifiedAt)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        sqlite3_bind_int(statement, 6, quarantined ? 1 : 0)
        bindOptionalInt64(stamp.deviceID, to: 7, in: statement)
        bindOptionalInt64(stamp.inode, to: 8, in: statement)
        bindOptionalInt64(stamp.modifiedSeconds, to: 9, in: statement)
        bindOptionalInt64(stamp.modifiedNanoseconds, to: 10, in: statement)
        bindOptionalInt64(stamp.changedSeconds, to: 11, in: statement)
        bindOptionalInt64(stamp.changedNanoseconds, to: 12, in: statement)
        try stepDone(statement, database: database, operation: "write legacy checkpoint")
    }

    private func bindOptionalInt64(
        _ value: Int64?,
        to index: Int32,
        in statement: OpaquePointer
    ) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
