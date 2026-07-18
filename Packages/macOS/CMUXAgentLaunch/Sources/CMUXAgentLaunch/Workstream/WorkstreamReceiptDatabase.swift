import CryptoKit
import Foundation
import SQLite3

/// SQLite receipt sidecar owned and serialized by `WorkstreamPersistence`.
///
/// This type is deliberately synchronous and non-Sendable. Its sole owner is
/// the persistence actor, which keeps receipt reservation, JSONL append, and
/// completion marking in one non-reentrant critical path.
final class WorkstreamReceiptDatabase {
    private let url: URL
    private let retention: TimeInterval
    private let maximumCount: Int
    private let maximumBytes: Int64
    private var database: OpaquePointer?

    init(
        url: URL,
        retention: TimeInterval,
        maximumCount: Int,
        maximumBytes: Int64
    ) {
        self.url = url
        self.retention = retention
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func reserve(
        source: String,
        sessionID: String,
        eventName: String,
        requestID: String,
        now: TimeInterval
    ) throws -> (itemID: UUID, appended: Bool, existedBeforeReservation: Bool) {
        let database = try databaseHandle()
        try execute("BEGIN IMMEDIATE;", in: database)
        var transactionOpen = true
        do {
            // Look up before retention cleanup. A delayed acknowledgement retry
            // must revive its exact receipt even if the app was down longer than
            // the nominal retention window.
            if let existing = try receipt(
                source: source,
                sessionID: sessionID,
                eventName: eventName,
                requestID: requestID,
                database: database
            ) {
                try touchReceipt(
                    source: source,
                    sessionID: sessionID,
                    eventName: eventName,
                    requestID: requestID,
                    now: now,
                    database: database
                )
                try execute("COMMIT;", in: database)
                transactionOpen = false
                try checkpoint(database)
                return (existing.itemID, existing.appended, true)
            }

            var count = try receiptCount(in: database)
            var reusablePages = try pragmaInt64("freelist_count", in: database)
            let pageCount = try pragmaInt64("page_count", in: database)
            let maximumPageCount = try pragmaInt64("max_page_count", in: database)
            let needsCleanup = count >= maximumCount
                || (pageCount >= maximumPageCount && reusablePages == 0)
                || (physicalBytes() >= maximumBytes && reusablePages == 0)
            if needsCleanup {
                try withStatement(
                    "DELETE FROM feed_receipts WHERE last_seen_at < ?;",
                    in: database
                ) { statement in
                    try bind(now - retention, at: 1, in: statement, database: database)
                    try stepDone(statement, database: database)
                }
                count = try receiptCount(in: database)
                reusablePages = try pragmaInt64("freelist_count", in: database)
            }

            guard count < maximumCount else {
                throw WorkstreamPersistenceError.receiptCountLimitReached(
                    maximumCount: maximumCount
                )
            }
            guard physicalBytes() < maximumBytes || reusablePages > 0 else {
                throw WorkstreamPersistenceError.receiptByteLimitReached(
                    maximumBytes: maximumBytes
                )
            }

            let itemID = stableItemID(
                source: source,
                sessionID: sessionID,
                eventName: eventName,
                requestID: requestID
            )
            try withStatement(
                """
                INSERT INTO feed_receipts (
                    source, session_id, event_name, request_id,
                    item_id, appended, created_at, last_seen_at
                ) VALUES (?, ?, ?, ?, ?, 0, ?, ?);
                """,
                in: database
            ) { statement in
                try bind(source, at: 1, in: statement, database: database)
                try bind(sessionID, at: 2, in: statement, database: database)
                try bind(eventName, at: 3, in: statement, database: database)
                try bind(requestID, at: 4, in: statement, database: database)
                try bind(itemID.uuidString, at: 5, in: statement, database: database)
                try bind(now, at: 6, in: statement, database: database)
                try bind(now, at: 7, in: statement, database: database)
                try stepDone(statement, database: database)
            }
            try execute("COMMIT;", in: database)
            transactionOpen = false
            try checkpoint(database)
            return (itemID, false, false)
        } catch {
            if transactionOpen {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
            throw mappedError(error)
        }
    }

    func markAppended(
        source: String,
        sessionID: String,
        eventName: String,
        requestID: String,
        itemID: UUID,
        now: TimeInterval
    ) throws {
        let database = try databaseHandle()
        try execute("BEGIN IMMEDIATE;", in: database)
        var transactionOpen = true
        do {
            try withStatement(
                """
                UPDATE feed_receipts
                SET appended = 1, last_seen_at = ?
                WHERE source = ? AND session_id = ? AND event_name = ?
                  AND request_id = ? AND item_id = ?;
                """,
                in: database
            ) { statement in
                try bind(now, at: 1, in: statement, database: database)
                try bind(source, at: 2, in: statement, database: database)
                try bind(sessionID, at: 3, in: statement, database: database)
                try bind(eventName, at: 4, in: statement, database: database)
                try bind(requestID, at: 5, in: statement, database: database)
                try bind(itemID.uuidString, at: 6, in: statement, database: database)
                try stepDone(statement, database: database)
            }
            guard sqlite3_changes(database) == 1 else {
                throw sqliteError(
                    code: SQLITE_NOTFOUND,
                    operation: "mark acknowledged Feed receipt appended",
                    database: database
                )
            }
            try execute("COMMIT;", in: database)
            transactionOpen = false
            try checkpoint(database)
        } catch {
            if transactionOpen {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
            throw mappedError(error)
        }
    }

    func clearIfPresent() throws {
        guard database != nil || FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let database = try databaseHandle()
        try execute("DELETE FROM feed_receipts;", in: database)
        try checkpoint(database)
    }

    private func receipt(
        source: String,
        sessionID: String,
        eventName: String,
        requestID: String,
        database: OpaquePointer
    ) throws -> (itemID: UUID, appended: Bool)? {
        try withStatement(
            """
            SELECT item_id, appended
            FROM feed_receipts
            WHERE source = ? AND session_id = ? AND event_name = ? AND request_id = ?;
            """,
            in: database
        ) { statement in
            try bind(source, at: 1, in: statement, database: database)
            try bind(sessionID, at: 2, in: statement, database: database)
            try bind(eventName, at: 3, in: statement, database: database)
            try bind(requestID, at: 4, in: statement, database: database)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else {
                throw sqliteError(
                    code: status,
                    operation: "read acknowledged Feed receipt",
                    database: database
                )
            }
            guard let text = sqlite3_column_text(statement, 0),
                  let itemID = UUID(uuidString: String(cString: text))
            else {
                throw sqliteError(
                    code: SQLITE_CORRUPT,
                    operation: "decode acknowledged Feed receipt UUID",
                    database: database
                )
            }
            return (itemID, sqlite3_column_int(statement, 1) != 0)
        }
    }

    private func touchReceipt(
        source: String,
        sessionID: String,
        eventName: String,
        requestID: String,
        now: TimeInterval,
        database: OpaquePointer
    ) throws {
        try withStatement(
            """
            UPDATE feed_receipts SET last_seen_at = ?
            WHERE source = ? AND session_id = ? AND event_name = ? AND request_id = ?;
            """,
            in: database
        ) { statement in
            try bind(now, at: 1, in: statement, database: database)
            try bind(source, at: 2, in: statement, database: database)
            try bind(sessionID, at: 3, in: statement, database: database)
            try bind(eventName, at: 4, in: statement, database: database)
            try bind(requestID, at: 5, in: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    private func receiptCount(in database: OpaquePointer) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM feed_receipts;", in: database) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW else {
                throw sqliteError(
                    code: status,
                    operation: "count acknowledged Feed receipts",
                    database: database
                )
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func databaseHandle() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &openedDatabase, flags, nil)
        guard status == SQLITE_OK, let openedDatabase else {
            if let openedDatabase { sqlite3_close_v2(openedDatabase) }
            throw sqliteError(
                code: status,
                operation: "open acknowledged Feed receipt database",
                database: openedDatabase
            )
        }
        sqlite3_extended_result_codes(openedDatabase, 1)
        sqlite3_busy_timeout(openedDatabase, 1_000)
        do {
            try configure(openedDatabase)
        } catch {
            sqlite3_close_v2(openedDatabase)
            throw mappedError(error)
        }
        database = openedDatabase
        return openedDatabase
    }

    private func configure(_ database: OpaquePointer) throws {
        let pageSize: Int64 = 4_096
        let minimumWALBudget = pageSize * 8
        let sharedMemoryBudget = pageSize * 8
        let walBudget = max(
            minimumWALBudget,
            min(4 * 1_024 * 1_024, maximumBytes / 4)
        )
        let databaseBudget = maximumBytes - walBudget - sharedMemoryBudget
        guard databaseBudget >= pageSize * 4 else {
            throw WorkstreamPersistenceError.receiptByteLimitReached(
                maximumBytes: maximumBytes
            )
        }
        let maximumPageCount = databaseBudget / pageSize
        let automaticCheckpointPages = max(1, walBudget / pageSize)

        try execute("PRAGMA page_size = \(pageSize);", in: database)
        try execute("PRAGMA max_page_count = \(maximumPageCount);", in: database)
        try execute("PRAGMA journal_mode = WAL;", in: database)
        try execute("PRAGMA synchronous = FULL;", in: database)
        try execute("PRAGMA journal_size_limit = \(walBudget);", in: database)
        try execute("PRAGMA wal_autocheckpoint = \(automaticCheckpointPages);", in: database)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS feed_receipts (
                source TEXT NOT NULL,
                session_id TEXT NOT NULL,
                event_name TEXT NOT NULL,
                request_id TEXT NOT NULL,
                item_id TEXT NOT NULL UNIQUE,
                appended INTEGER NOT NULL DEFAULT 0 CHECK (appended IN (0, 1)),
                created_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                PRIMARY KEY (source, session_id, event_name, request_id)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS feed_receipts_last_seen
                ON feed_receipts(last_seen_at);
            """,
            in: database
        )
        try checkpoint(database)
    }

    private func checkpoint(_ database: OpaquePointer) throws {
        let status = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            nil,
            nil
        )
        guard status == SQLITE_OK else {
            throw sqliteError(
                code: status,
                operation: "checkpoint acknowledged Feed receipt WAL",
                database: database
            )
        }
    }

    private func physicalBytes() -> Int64 {
        [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
        ]
            .reduce(into: Int64(0)) { total, fileURL in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let size = attributes[.size] as? NSNumber
                else { return }
                total += size.int64Value
            }
    }

    private func stableItemID(
        source: String,
        sessionID: String,
        eventName: String,
        requestID: String
    ) -> UUID {
        var identity = Data("cmux.feed.receipt.v1".utf8)
        for component in [source, sessionID, eventName, requestID] {
            let bytes = Data(component.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { identity.append(contentsOf: $0) }
            identity.append(bytes)
        }

        var bytes = Array(SHA256.hash(data: identity).prefix(16))
        // RFC 9562 version 8 reserves the payload for application-defined UUIDs.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func pragmaInt64(
        _ name: String,
        in database: OpaquePointer
    ) throws -> Int64 {
        try withStatement("PRAGMA \(name);", in: database) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW else {
                throw sqliteError(
                    code: status,
                    operation: "read SQLite pragma \(name)",
                    database: database
                )
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
            if let message { sqlite3_free(message) }
            throw sqliteError(
                code: status,
                operation: detail ?? "execute SQLite statement",
                database: database
            )
        }
    }

    private func withStatement<Result>(
        _ sql: String,
        in database: OpaquePointer,
        body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw sqliteError(
                code: status,
                operation: "prepare SQLite statement",
                database: database
            )
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(
        _ value: String,
        at index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let byteCount = value.lengthOfBytes(using: .utf8)
        guard byteCount <= Int(Int32.max) else {
            throw sqliteError(
                code: SQLITE_TOOBIG,
                operation: "bind SQLite text",
                database: database
            )
        }
        let status = value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                Int32(byteCount),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard status == SQLITE_OK else {
            throw sqliteError(code: status, operation: "bind SQLite text", database: database)
        }
    }

    private func bind(
        _ value: TimeInterval,
        at index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let status = sqlite3_bind_double(statement, index, value)
        guard status == SQLITE_OK else {
            throw sqliteError(code: status, operation: "bind SQLite number", database: database)
        }
    }

    private func stepDone(
        _ statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw sqliteError(code: status, operation: "step SQLite statement", database: database)
        }
    }

    private func mappedError(_ error: Error) -> Error {
        if let persistenceError = error as? WorkstreamPersistenceError {
            return persistenceError
        }
        let nsError = error as NSError
        let sqliteCode = Int32(nsError.code)
        if nsError.domain == Self.sqliteErrorDomain,
           sqliteCode & 0xFF == SQLITE_FULL {
            return WorkstreamPersistenceError.receiptByteLimitReached(
                maximumBytes: maximumBytes
            )
        }
        return error
    }

    private func sqliteError(
        code: Int32,
        operation: String,
        database: OpaquePointer?
    ) -> NSError {
        let message = database
            .flatMap(sqlite3_errmsg)
            .map { String(cString: $0) }
            ?? "unknown SQLite error"
        return NSError(
            domain: Self.sqliteErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(message)"]
        )
    }

    private static let sqliteErrorDomain = "CMUXAgentLaunch.WorkstreamPersistence.SQLite"
}
