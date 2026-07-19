import Foundation
import SQLite3
import Testing
@testable import CmuxFoundation

@Suite("Agent session registry partial migrations", .serialized)
struct CmuxAgentSessionRegistryPartialMigrationTests {
    @Test("v4 byte-accounting migration repairs every partial column state")
    func repairsPartialV5Migration() throws {
        for columns in [
            ["record_bytes"],
            ["slot_bytes"],
            ["record_bytes", "slot_bytes"],
        ] {
            let fixture = try MigrationFixture(
                version: 4,
                metadataColumns: columns,
                legacyColumns: [],
                installLegacyRecordTrigger: true
            )
            defer { fixture.remove() }

            let metrics = try fixture.registry.hookStorageMetrics(provider: "codex")

            #expect(metrics.recordBytes == 2)
            #expect(metrics.activeSlotBytes == 2)
            #expect(try fixture.userVersion() == 7)
            #expect(try fixture.columnCount(table: "agent_provider_metadata", named: "record_bytes") == 1)
            #expect(try fixture.columnCount(table: "agent_provider_metadata", named: "slot_bytes") == 1)
            let triggers = try fixture.revisionTriggers()
            #expect(triggers.count == 6)
            #expect(triggers["agent_sessions_revision_insert"]?.contains("record_bytes") == true)
            #expect(triggers["agent_active_slots_revision_insert"]?.contains("slot_bytes") == true)
        }
    }

    @Test("v5 quarantine migration accepts an already-added column")
    func repairsPartialV6Migration() throws {
        let fixture = try MigrationFixture(
            version: 5,
            metadataColumns: ["record_bytes", "slot_bytes"],
            legacyColumns: ["quarantined"]
        )
        defer { fixture.remove() }

        _ = try fixture.registry.hookStorageMetrics(provider: "codex")

        #expect(try fixture.userVersion() == 7)
        #expect(try fixture.columnCount(table: "agent_legacy_sources", named: "quarantined") == 1)
    }

    @Test("v6 revision-identity migration repairs partial and complete column states")
    func repairsPartialV7Migration() throws {
        let identityColumns = [
            "device_id",
            "inode",
            "modified_seconds",
            "modified_nanoseconds",
            "changed_seconds",
            "changed_nanoseconds",
        ]
        for columns in [Array(identityColumns.prefix(3)), identityColumns] {
            let fixture = try MigrationFixture(
                version: 6,
                metadataColumns: ["record_bytes", "slot_bytes"],
                legacyColumns: ["quarantined"] + columns
            )
            defer { fixture.remove() }

            _ = try fixture.registry.hookStorageMetrics(provider: "codex")

            #expect(try fixture.userVersion() == 7)
            for column in identityColumns {
                #expect(try fixture.columnCount(table: "agent_legacy_sources", named: column) == 1)
            }
        }
    }
}

private final class MigrationFixture {
    let directory: URL
    let registry: CmuxAgentSessionRegistry

    init(
        version: Int,
        metadataColumns: [String],
        legacyColumns: [String],
        installLegacyRecordTrigger: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-partial-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        registry = CmuxAgentSessionRegistry(url: url, busyTimeoutMilliseconds: 250)

        let metadataExtras = metadataColumns.map {
            ", \($0) INTEGER NOT NULL DEFAULT 0"
        }.joined()
        let legacyExtras = legacyColumns.map {
            if $0 == "quarantined" {
                return ", quarantined INTEGER NOT NULL DEFAULT 0"
            }
            return ", \($0) INTEGER"
        }.joined()
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE agent_sessions (
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            updated_at REAL NOT NULL,
            writer_generation INTEGER NOT NULL,
            workspace_id TEXT,
            surface_id TEXT,
            runtime_id TEXT,
            completed_at REAL,
            restore_authority INTEGER,
            parent_session_id TEXT,
            active_run_id TEXT,
            record_json BLOB NOT NULL,
            PRIMARY KEY (provider, session_id)
        ) WITHOUT ROWID;
        CREATE TABLE agent_active_slots (
            provider TEXT NOT NULL,
            scope TEXT NOT NULL,
            scope_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            updated_at REAL NOT NULL,
            writer_generation INTEGER NOT NULL,
            record_json BLOB NOT NULL,
            PRIMARY KEY (provider, scope, scope_id)
        ) WITHOUT ROWID;
        CREATE TABLE agent_legacy_sources (
            provider TEXT NOT NULL,
            path TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            imported_at REAL NOT NULL
            \(legacyExtras),
            PRIMARY KEY (provider, path)
        ) WITHOUT ROWID;
        CREATE TABLE agent_provider_metadata (
            provider TEXT NOT NULL PRIMARY KEY,
            revision INTEGER NOT NULL DEFAULT 0,
            projected_revision INTEGER NOT NULL DEFAULT 0,
            last_pruned_at REAL NOT NULL DEFAULT 0
            \(metadataExtras)
        ) WITHOUT ROWID;
        INSERT INTO agent_sessions (
            provider, session_id, updated_at, writer_generation, record_json
        ) VALUES ('codex', 'session', 1, 1, x'7b7d');
        INSERT INTO agent_active_slots (
            provider, scope, scope_id, session_id, updated_at, writer_generation, record_json
        ) VALUES ('codex', 'surface', 'surface', 'session', 1, 1, x'7b7d');
        INSERT INTO agent_provider_metadata (
            provider, revision, projected_revision, last_pruned_at
        ) VALUES ('codex', 1, 0, 0);
        PRAGMA user_version=\(version);
        """
        try Self.execute(schema, database: database)
        if installLegacyRecordTrigger {
            try Self.execute(
                """
                CREATE TRIGGER agent_sessions_revision_insert
                AFTER INSERT ON agent_sessions BEGIN
                    UPDATE agent_provider_metadata SET revision = revision + 1
                    WHERE provider = NEW.provider;
                END;
                """,
                database: database
            )
        }
        let assignments = metadataColumns.map { "\($0) = 999" }.joined(separator: ", ")
        if !assignments.isEmpty {
            try Self.execute(
                "UPDATE agent_provider_metadata SET \(assignments)",
                database: database
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func userVersion() throws -> Int {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw Self.error(database) }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.error(database) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func columnCount(table: String, named name: String) throws -> Int {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw Self.error(database) }
            defer { sqlite3_finalize(statement) }
            var count = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawName = sqlite3_column_text(statement, 1) else { continue }
                if String(cString: rawName) == name { count += 1 }
            }
            return count
        }
    }

    func revisionTriggers() throws -> [String: String] {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%_revision_%'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { throw Self.error(database) }
            defer { sqlite3_finalize(statement) }
            var result: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawName = sqlite3_column_text(statement, 0),
                      let rawSQL = sqlite3_column_text(statement, 1) else { continue }
                result[String(cString: rawName)] = String(cString: rawSQL)
            }
            return result
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            registry.url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private static func execute(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw error(database)
        }
    }

    private static func error(_ database: OpaquePointer) -> NSError {
        NSError(
            domain: "CmuxAgentSessionRegistryPartialMigrationTests",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }
}
