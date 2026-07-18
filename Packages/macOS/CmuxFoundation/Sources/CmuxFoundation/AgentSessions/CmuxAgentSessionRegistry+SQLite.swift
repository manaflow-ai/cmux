public import Foundation
import Darwin
import SQLite3

extension CmuxAgentSessionRegistry {
    func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let stateDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: stateDirectory.path
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            defer { if let database { sqlite3_close(database) } }
            throw error(database, operation: "open")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        if try schemaVersion(database) < 1 {
            try execute(database, sql: "PRAGMA journal_mode=WAL")
            try migrate(database)
        }
        try execute(database, sql: "PRAGMA synchronous=NORMAL")
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            if FileManager.default.fileExists(atPath: path) {
                _ = chmod(path, S_IRUSR | S_IWUSR)
            }
        }
        return try body(database)
    }

    func schemaVersion(_ database: OpaquePointer) throws -> Int {
        let statement = try prepare(database, "PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw error(database, operation: "read schema version")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func migrate(_ database: OpaquePointer) throws {
        try execute(
            database,
            sql: """
            CREATE TABLE IF NOT EXISTS agent_sessions (
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
            CREATE INDEX IF NOT EXISTS agent_sessions_runtime
                ON agent_sessions(runtime_id, provider, updated_at DESC);
            CREATE INDEX IF NOT EXISTS agent_sessions_panel
                ON agent_sessions(workspace_id, surface_id, provider, updated_at DESC);
            CREATE TABLE IF NOT EXISTS agent_active_slots (
                provider TEXT NOT NULL,
                scope TEXT NOT NULL,
                scope_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                updated_at REAL NOT NULL,
                writer_generation INTEGER NOT NULL,
                record_json BLOB NOT NULL,
                PRIMARY KEY (provider, scope, scope_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS agent_legacy_sources (
                provider TEXT NOT NULL,
                path TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_at REAL NOT NULL,
                imported_at REAL NOT NULL,
                PRIMARY KEY (provider, path)
            ) WITHOUT ROWID;
            PRAGMA user_version=1;
            """
        )
    }

    func readRecords(database: OpaquePointer, provider: String) throws -> [Record] {
        let statement = try prepare(
            database,
            """
            SELECT session_id, updated_at, writer_generation, record_json
            FROM agent_sessions WHERE provider = ?1 ORDER BY updated_at DESC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        var result: [Record] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionID = text(statement, column: 0), let json = data(statement, column: 3) else { continue }
            result.append(Record(
                provider: provider,
                sessionID: sessionID,
                updatedAt: sqlite3_column_double(statement, 1),
                writerGeneration: Int(sqlite3_column_int64(statement, 2)),
                json: json
            ))
        }
        return result
    }

    func readRecord(database: OpaquePointer, provider: String, sessionID: String) throws -> Record? {
        let statement = try prepare(
            database,
            """
            SELECT updated_at, writer_generation, record_json FROM agent_sessions
            WHERE provider = ?1 AND session_id = ?2
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(sessionID, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let json = data(statement, column: 2) else { return nil }
        return Record(
            provider: provider,
            sessionID: sessionID,
            updatedAt: sqlite3_column_double(statement, 0),
            writerGeneration: Int(sqlite3_column_int64(statement, 1)),
            json: json
        )
    }

    func readRecordCount(database: OpaquePointer, provider: String) throws -> Int {
        let statement = try prepare(
            database,
            "SELECT COUNT(*) FROM agent_sessions WHERE provider = ?1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw error(database, operation: "count sessions")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func readSlots(database: OpaquePointer, provider: String) throws -> [ActiveSlot] {
        let statement = try prepare(
            database,
            """
            SELECT scope, scope_id, session_id, updated_at, writer_generation, record_json
            FROM agent_active_slots WHERE provider = ?1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        var result: [ActiveSlot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let scopeValue = text(statement, column: 0),
                  let scope = Scope(rawValue: scopeValue),
                  let scopeID = text(statement, column: 1),
                  let sessionID = text(statement, column: 2),
                  let json = data(statement, column: 5) else { continue }
            result.append(ActiveSlot(
                provider: provider,
                scope: scope,
                scopeID: scopeID,
                sessionID: sessionID,
                updatedAt: sqlite3_column_double(statement, 3),
                writerGeneration: Int(sqlite3_column_int64(statement, 4)),
                json: json
            ))
        }
        return result
    }

    func readSlot(
        database: OpaquePointer,
        provider: String,
        scope: Scope,
        scopeID: String
    ) throws -> ActiveSlot? {
        let statement = try prepare(
            database,
            """
            SELECT session_id, updated_at, writer_generation, record_json
            FROM agent_active_slots
            WHERE provider = ?1 AND scope = ?2 AND scope_id = ?3
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(scope.rawValue, to: 2, in: statement)
        try bind(scopeID, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let sessionID = text(statement, column: 0),
              let json = data(statement, column: 3) else { return nil }
        return ActiveSlot(
            provider: provider,
            scope: scope,
            scopeID: scopeID,
            sessionID: sessionID,
            updatedAt: sqlite3_column_double(statement, 1),
            writerGeneration: Int(sqlite3_column_int64(statement, 2)),
            json: json
        )
    }

    func persistSnapshotChangesOptimistically(
        provider: String,
        previous: Snapshot,
        current: Snapshot
    ) throws {
        let previousRecords = Dictionary(uniqueKeysWithValues: previous.records.map { ($0.sessionID, $0) })
        let currentRecords = Dictionary(uniqueKeysWithValues: current.records.map { ($0.sessionID, $0) })
        let previousRecordIDs = Set(previousRecords.keys)
        let currentRecordIDs = Set(currentRecords.keys)
        let recordMembershipChanged = previousRecordIDs != currentRecordIDs
        var recordUpserts: [Record] = []
        for var record in current.records {
            record.provider = provider
            let old = previousRecords[record.sessionID]
            if old?.updatedAt != record.updatedAt
                || old?.writerGeneration != record.writerGeneration
                || old?.json != record.json {
                recordUpserts.append(record)
            }
        }
        let recordDeletes = previousRecordIDs.subtracting(currentRecordIDs)

        let previousSlots = Dictionary(uniqueKeysWithValues: previous.activeSlots.map {
            (Self.slotKey(scope: $0.scope, scopeID: $0.scopeID), $0)
        })
        let currentSlots = Dictionary(uniqueKeysWithValues: current.activeSlots.map {
            (Self.slotKey(scope: $0.scope, scopeID: $0.scopeID), $0)
        })
        var slotUpserts: [ActiveSlot] = []
        for var slot in current.activeSlots {
            slot.provider = provider
            let key = Self.slotKey(scope: slot.scope, scopeID: slot.scopeID)
            let old = previousSlots[key]
            if old?.updatedAt != slot.updatedAt
                || old?.writerGeneration != slot.writerGeneration
                || old?.sessionID != slot.sessionID
                || old?.json != slot.json {
                slotUpserts.append(slot)
            }
        }
        let slotDeleteKeys = Set(previousSlots.keys).subtracting(currentSlots.keys)
        guard !recordUpserts.isEmpty || !recordDeletes.isEmpty
                || !slotUpserts.isEmpty || !slotDeleteKeys.isEmpty else { return }

        try withDatabase { database in
            // mutateSnapshot owns the replay budget. Avoid multiplying it by
            // the generic BEGIN retry budget when another process holds the
            // writer lock for the full busy timeout.
            try transaction(database, retryBeginContention: false) {
                if recordMembershipChanged,
                   try readRecordCount(database: database, provider: provider) != previousRecords.count {
                    throw mutationConflictError()
                }
                for record in recordUpserts {
                    guard recordsMatch(
                        try readRecord(database: database, provider: provider, sessionID: record.sessionID),
                        previousRecords[record.sessionID]
                    ) else { throw mutationConflictError() }
                }
                for sessionID in recordDeletes {
                    guard recordsMatch(
                        try readRecord(database: database, provider: provider, sessionID: sessionID),
                        previousRecords[sessionID]
                    ) else { throw mutationConflictError() }
                }
                for slot in slotUpserts {
                    let key = Self.slotKey(scope: slot.scope, scopeID: slot.scopeID)
                    guard slotsMatch(
                        try readSlot(
                            database: database,
                            provider: provider,
                            scope: slot.scope,
                            scopeID: slot.scopeID
                        ),
                        previousSlots[key]
                    ) else { throw mutationConflictError() }
                }
                for key in slotDeleteKeys {
                    guard let previousSlot = previousSlots[key],
                          slotsMatch(
                            try readSlot(
                                database: database,
                                provider: provider,
                                scope: previousSlot.scope,
                                scopeID: previousSlot.scopeID
                            ),
                            previousSlot
                          ) else { throw mutationConflictError() }
                }

                for record in recordUpserts { try upsert(record, database: database) }
                for sessionID in recordDeletes {
                    try deleteSession(
                        database: database,
                        provider: provider,
                        sessionID: sessionID,
                        maximumWriterGeneration: Self.currentWriterGeneration
                    )
                }
                for slot in slotUpserts { try upsert(slot, database: database) }
                for key in slotDeleteKeys {
                    guard let previousSlot = previousSlots[key] else { continue }
                    try deleteSlot(
                        database: database,
                        provider: provider,
                        scope: previousSlot.scope,
                        scopeID: previousSlot.scopeID,
                        maximumWriterGeneration: Self.currentWriterGeneration
                    )
                }
            }
        }
    }

    func recordsMatch(_ lhs: Record?, _ rhs: Record?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            lhs.provider == rhs.provider
                && lhs.sessionID == rhs.sessionID
                && lhs.updatedAt == rhs.updatedAt
                && lhs.writerGeneration == rhs.writerGeneration
                && lhs.json == rhs.json
        default: false
        }
    }

    func slotsMatch(_ lhs: ActiveSlot?, _ rhs: ActiveSlot?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            lhs.provider == rhs.provider
                && lhs.scope == rhs.scope
                && lhs.scopeID == rhs.scopeID
                && lhs.sessionID == rhs.sessionID
                && lhs.updatedAt == rhs.updatedAt
                && lhs.writerGeneration == rhs.writerGeneration
                && lhs.json == rhs.json
        default: false
        }
    }

    func mutationConflictError() -> NSError {
        NSError(
            domain: "CmuxAgentSessionRegistry",
            code: Self.optimisticConflictCode,
            userInfo: [NSLocalizedDescriptionKey: "agent session snapshot changed concurrently"]
        )
    }

    func isRetryableMutationError(_ error: any Error) -> Bool {
        let error = error as NSError
        guard error.domain == "CmuxAgentSessionRegistry" else { return false }
        if error.code == Self.optimisticConflictCode { return true }
        let primarySQLiteCode = Int32(error.code & 0xFF)
        return primarySQLiteCode == SQLITE_BUSY || primarySQLiteCode == SQLITE_LOCKED
    }

    func upsert(_ record: Record, database: OpaquePointer) throws {
        let metadata = (try? JSONSerialization.jsonObject(with: record.json) as? [String: Any]) ?? [:]
        let runtime = metadata["cmuxRuntime"] as? [String: Any]
        let statement = try prepare(
            database,
            """
            INSERT INTO agent_sessions (
                provider, session_id, updated_at, writer_generation, workspace_id,
                surface_id, runtime_id, completed_at, restore_authority,
                parent_session_id, active_run_id, record_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(provider, session_id) DO UPDATE SET
                updated_at = excluded.updated_at,
                writer_generation = excluded.writer_generation,
                workspace_id = excluded.workspace_id,
                surface_id = excluded.surface_id,
                runtime_id = excluded.runtime_id,
                completed_at = excluded.completed_at,
                restore_authority = excluded.restore_authority,
                parent_session_id = excluded.parent_session_id,
                active_run_id = excluded.active_run_id,
                record_json = excluded.record_json
            WHERE excluded.writer_generation >= agent_sessions.writer_generation
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(record.provider, to: 1, in: statement)
        try bind(record.sessionID, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, record.updatedAt)
        sqlite3_bind_int64(statement, 4, sqlite3_int64(record.writerGeneration))
        try bind(metadata["workspaceId"] as? String, to: 5, in: statement)
        try bind(metadata["surfaceId"] as? String, to: 6, in: statement)
        try bind(runtime?["id"] as? String, to: 7, in: statement)
        try bind(metadata["completedAt"] as? Double, to: 8, in: statement)
        try bind(metadata["restoreAuthority"] as? Bool, to: 9, in: statement)
        try bind(metadata["parentSessionId"] as? String, to: 10, in: statement)
        try bind(metadata["activeRunId"] as? String, to: 11, in: statement)
        try bind(record.json, to: 12, in: statement)
        try stepDone(statement, database: database, operation: "upsert session")
    }

    func upsert(_ slot: ActiveSlot, database: OpaquePointer) throws {
        let statement = try prepare(
            database,
            """
            INSERT INTO agent_active_slots (
                provider, scope, scope_id, session_id, updated_at, writer_generation, record_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(provider, scope, scope_id) DO UPDATE SET
                session_id = excluded.session_id,
                updated_at = excluded.updated_at,
                writer_generation = excluded.writer_generation,
                record_json = excluded.record_json
            WHERE excluded.writer_generation >= agent_active_slots.writer_generation
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(slot.provider, to: 1, in: statement)
        try bind(slot.scope.rawValue, to: 2, in: statement)
        try bind(slot.scopeID, to: 3, in: statement)
        try bind(slot.sessionID, to: 4, in: statement)
        sqlite3_bind_double(statement, 5, slot.updatedAt)
        sqlite3_bind_int64(statement, 6, sqlite3_int64(slot.writerGeneration))
        try bind(slot.json, to: 7, in: statement)
        try stepDone(statement, database: database, operation: "upsert active slot")
    }

    func deleteSession(
        database: OpaquePointer,
        provider: String,
        sessionID: String,
        maximumWriterGeneration: Int
    ) throws {
        let statement = try prepare(
            database,
            """
            DELETE FROM agent_sessions
            WHERE provider = ?1 AND session_id = ?2 AND writer_generation <= ?3
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(sessionID, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(maximumWriterGeneration))
        try stepDone(statement, database: database, operation: "delete session")
    }

    func deleteSlot(
        database: OpaquePointer,
        provider: String,
        scope: Scope,
        scopeID: String,
        maximumWriterGeneration: Int
    ) throws {
        let statement = try prepare(
            database,
            """
            DELETE FROM agent_active_slots
            WHERE provider = ?1 AND scope = ?2 AND scope_id = ?3 AND writer_generation <= ?4
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(scope.rawValue, to: 2, in: statement)
        try bind(scopeID, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, sqlite3_int64(maximumWriterGeneration))
        try stepDone(statement, database: database, operation: "delete active slot")
    }

    func removeActiveSlots(
        database: OpaquePointer,
        provider: String,
        sessionID: String,
        removal: ActiveSlotRemoval,
        maximumWriterGeneration: Int
    ) throws {
        let sql: String
        switch removal {
        case .all:
            sql = """
            DELETE FROM agent_active_slots
            WHERE provider = ?1 AND session_id = ?2 AND writer_generation <= ?3
            """
        case .updatedThrough:
            sql = """
            DELETE FROM agent_active_slots
            WHERE provider = ?1 AND session_id = ?2
              AND writer_generation <= ?3 AND updated_at <= ?4
            """
        }
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        try bind(provider, to: 1, in: statement)
        try bind(sessionID, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(maximumWriterGeneration))
        if case let .updatedThrough(updatedAt) = removal {
            sqlite3_bind_double(statement, 4, updatedAt)
        }
        try stepDone(statement, database: database, operation: "remove session active slots")
    }

    func transaction<T>(
        _ database: OpaquePointer,
        retryBeginContention: Bool = true,
        body: () throws -> T
    ) throws -> T {
        var lastContentionError: (any Error)?
        let attemptCount = retryBeginContention && busyTimeoutMilliseconds > 0
            ? Self.maximumMutationAttempts
            : 1
        for attempt in 0..<attemptCount {
            do {
                try execute(database, sql: "BEGIN IMMEDIATE")
                lastContentionError = nil
                break
            } catch {
                guard isRetryableMutationError(error), attempt + 1 < attemptCount else { throw error }
                lastContentionError = error
            }
        }
        if let lastContentionError { throw lastContentionError }
        do {
            let result = try body()
            try execute(database, sql: "COMMIT")
            return result
        } catch {
            try? execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    func readTransaction<T>(_ database: OpaquePointer, body: () throws -> T) throws -> T {
        try execute(database, sql: "BEGIN")
        do {
            let result = try body()
            try execute(database, sql: "COMMIT")
            return result
        } catch {
            try? execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    func execute(_ database: OpaquePointer, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
            sqlite3_free(message)
            throw NSError(
                domain: "CmuxAgentSessionRegistry",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: detail ?? "SQLite execution failed"]
            )
        }
    }

    func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error(database, operation: "prepare")
        }
        return statement
    }

    func stepDone(_ statement: OpaquePointer, database: OpaquePointer, operation: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(database, operation: operation) }
    }

    func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw bindingError(result) }
    }

    func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw bindingError(result) }
    }

    func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) throws {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    func bind(_ value: Bool?, to index: Int32, in statement: OpaquePointer) throws {
        if let value { sqlite3_bind_int(statement, index, value ? 1 : 0) } else { sqlite3_bind_null(statement, index) }
    }

    func text(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    func data(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    func error(_ database: OpaquePointer?, operation: String) -> NSError {
        NSError(
            domain: "CmuxAgentSessionRegistry",
            code: Int(database.map(sqlite3_errcode) ?? SQLITE_ERROR),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation): \(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable")"
            ]
        )
    }

    func bindingError(_ code: Int32) -> NSError {
        NSError(
            domain: "CmuxAgentSessionRegistry",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "SQLite bind failed"]
        )
    }

    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
