import Foundation
import SQLite3

extension CmuxAgentSessionRegistry {
    func deleteLegacyRows(database: OpaquePointer, provider: String) throws {
        for table in ["agent_sessions", "agent_active_slots"] {
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
        let statement = try prepare(
            database,
            """
            SELECT size, modified_at FROM agent_legacy_sources
            WHERE provider = ?1 AND path = ?2
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(stamp.path, to: 2, in: statement)
        guard try stepRow(statement, database: database, operation: "read legacy checkpoint") else {
            return false
        }
        return sqlite3_column_int64(statement, 0) == stamp.size
            && abs(sqlite3_column_double(statement, 1) - stamp.modifiedAt) < 0.000_001
    }

    func replaceLegacy(
        database: OpaquePointer,
        provider: String,
        stamp: LegacyStamp,
        payload: LegacyPayload
    ) throws {
        try deleteLegacyRows(database: database, provider: provider)
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
        try writeLegacyStamp(database: database, provider: provider, stamp: stamp)
    }

    func writeLegacyStamp(
        database: OpaquePointer,
        provider: String,
        stamp: LegacyStamp
    ) throws {
        let statement = try prepare(
            database,
            """
            INSERT INTO agent_legacy_sources (provider, path, size, modified_at, imported_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(provider, path) DO UPDATE SET
                size = excluded.size,
                modified_at = excluded.modified_at,
                imported_at = excluded.imported_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(stamp.path, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, stamp.size)
        sqlite3_bind_double(statement, 4, stamp.modifiedAt)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        try stepDone(statement, database: database, operation: "write legacy checkpoint")
    }
}
