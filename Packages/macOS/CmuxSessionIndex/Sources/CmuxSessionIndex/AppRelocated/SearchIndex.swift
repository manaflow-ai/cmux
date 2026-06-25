import CmuxFoundation
import Foundation
import SQLite3

enum GlobalSearchKind: String, Codable, Sendable {
    case browser
    case markdown
    case title

    var localizedLabel: String {
        switch self {
        case .browser:
            return String(localized: "globalSearch.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "globalSearch.kind.markdown", defaultValue: "Markdown")
        case .title:
            return String(localized: "globalSearch.kind.title", defaultValue: "Title")
        }
    }
}

struct SearchIndexDocument: Sendable, Equatable {
    let id: String
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID?
    let kind: GlobalSearchKind
    let title: String
    let location: String
    let anchor: String
    let text: String
    let timestamp: Date

    init(
        id: String,
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID?,
        kind: GlobalSearchKind,
        title: String,
        location: String,
        anchor: String,
        text: String,
        timestamp: Date = Date.now
    ) {
        self.id = id
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.kind = kind
        self.title = title
        self.location = location
        self.anchor = anchor
        self.text = text
        self.timestamp = timestamp
    }

    static func panelStableID(
        panelID: UUID,
        kind: GlobalSearchKind,
        subtype: String = "document"
    ) -> String {
        [
            panelID.uuidString,
            kind.rawValue,
            subtype
        ].joined(separator: ":")
    }
}

struct SearchIndexHit: Identifiable, Sendable, Equatable {
    let id: String
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID?
    let kind: GlobalSearchKind
    let title: String
    let location: String
    let anchor: String
    let snippet: String
    let rank: Double
    let timestamp: Date
}

enum SearchIndexError: LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "SQLite open failed: \(message)"
        case let .executeFailed(message):
            return "SQLite execute failed: \(message)"
        case let .prepareFailed(message):
            return "SQLite prepare failed: \(message)"
        case let .bindFailed(message):
            return "SQLite bind failed: \(message)"
        case let .stepFailed(message):
            return "SQLite step failed: \(message)"
        }
    }
}

actor SearchIndex {
    private static let schemaVersion = 1

    private var database: OpaquePointer?

    nonisolated static func open(databaseURL: URL = .cmuxSearchDatabaseURL) async throws -> SearchIndex {
        // Actor initializers run on the caller executor, so open SQLite off the MainActor.
        try await Task.detached(priority: .utility) {
            try SearchIndex(databaseURL: databaseURL)
        }.value
    }

    init(databaseURL: URL = .cmuxSearchDatabaseURL) throws {
        try Self.ensureParentDirectoryExists(for: databaseURL)

        var openedDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase?.sqliteErrorMessage ?? "unknown SQLite open failure"
            sqlite3_close(openedDatabase)
            throw SearchIndexError.openFailed(message)
        }

        database = openedDatabase
        sqlite3_extended_result_codes(openedDatabase, 1)
        try Self.configureDatabase(openedDatabase)
    }

    deinit {
        sqlite3_close(database)
    }

    func upsert(_ document: SearchIndexDocument) throws {
        try Task.checkCancellation()

        let sql = """
            INSERT INTO chunks (
                id, window_id, workspace_id, panel_id, kind,
                title, location, anchor, ts, text
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(id) DO UPDATE SET
                window_id = excluded.window_id,
                workspace_id = excluded.workspace_id,
                panel_id = excluded.panel_id,
                kind = excluded.kind,
                title = excluded.title,
                location = excluded.location,
                anchor = excluded.anchor,
                ts = excluded.ts,
                text = excluded.text
            """

        try withStatement(sql) { statement in
            try bind(document.id, at: 1, in: statement)
            try bind(document.windowID.uuidString, at: 2, in: statement)
            try bind(document.workspaceID.uuidString, at: 3, in: statement)
            if let panelID = document.panelID {
                try bind(panelID.uuidString, at: 4, in: statement)
            } else {
                try bindNull(at: 4, in: statement)
            }
            try bind(document.kind.rawValue, at: 5, in: statement)
            try bind(document.title, at: 6, in: statement)
            try bind(document.location, at: 7, in: statement)
            try bind(document.anchor, at: 8, in: statement)
            try bind(document.timestamp.timeIntervalSince1970, at: 9, in: statement)
            try bind(document.text, at: 10, in: statement)
            try stepDone(statement)
        }
    }

    func deletePanel(_ panelID: UUID) throws {
        try withStatement("DELETE FROM chunks WHERE panel_id = ?1") { statement in
            try bind(panelID.uuidString, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    func deleteDocument(id: String) throws {
        try withStatement("DELETE FROM chunks WHERE id = ?1") { statement in
            try bind(id, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    func deleteAll() throws {
        try execute("DELETE FROM chunks")
    }

    func search(_ rawQuery: String, limit: Int = 20) throws -> [SearchIndexHit] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        guard let matchQuery = Self.matchQuery(for: trimmed) else { return [] }

        let sql = """
            SELECT
                c.id,
                c.window_id,
                c.workspace_id,
                c.panel_id,
                c.kind,
                c.title,
                c.location,
                c.anchor,
                c.ts,
                snippet(chunks_fts, 2, '', '', '...', 14) AS snippet,
                bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.rowid = chunks_fts.rowid
            WHERE chunks_fts MATCH ?1
            ORDER BY rank ASC, c.ts DESC
            LIMIT ?2
            """

        return try withStatement(sql) { statement in
            try bind(matchQuery, at: 1, in: statement)
            let limitBindResult = sqlite3_bind_int64(statement, 2, sqlite3_int64(limit))
            guard limitBindResult == SQLITE_OK else {
                throw SearchIndexError.bindFailed(
                    database?.sqliteErrorMessage ?? "bind failed with code \(limitBindResult)"
                )
            }

            var hits: [SearchIndexHit] = []
            while true {
                let stepResult = sqlite3_step(statement)
                switch stepResult {
                case SQLITE_ROW:
                    guard let hit = Self.hit(from: statement) else { continue }
                    hits.append(hit)
                case SQLITE_DONE:
                    return hits
                default:
                    throw SearchIndexError.stepFailed(database?.sqliteErrorMessage ?? "step failed with code \(stepResult)")
                }
            }
        }
    }

    #if DEBUG
    func clearForTesting() throws {
        try deleteAll()
    }
    #endif

    private static func configureDatabase(_ database: OpaquePointer) throws {
        let existingSchemaVersion = try userVersion(database)

        try execute("PRAGMA journal_mode = WAL", database: database)
        try execute("PRAGMA synchronous = NORMAL", database: database)
        try execute("""
            CREATE TABLE IF NOT EXISTS chunks (
                rowid INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                window_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                panel_id TEXT,
                kind TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                location TEXT NOT NULL DEFAULT '',
                anchor TEXT NOT NULL DEFAULT '',
                ts REAL NOT NULL,
                text TEXT NOT NULL DEFAULT ''
            )
            """, database: database)
        try execute("CREATE INDEX IF NOT EXISTS chunks_panel_idx ON chunks(panel_id)", database: database)
        try execute("CREATE INDEX IF NOT EXISTS chunks_workspace_idx ON chunks(workspace_id)", database: database)
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                title,
                location,
                text,
                content = 'chunks',
                content_rowid = 'rowid',
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """, database: database)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunks_fts(rowid, title, location, text)
                VALUES (new.rowid, new.title, new.location, new.text);
            END
            """, database: database)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, title, location, text)
                VALUES('delete', old.rowid, old.title, old.location, old.text);
            END
            """, database: database)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, title, location, text)
                VALUES('delete', old.rowid, old.title, old.location, old.text);
                INSERT INTO chunks_fts(rowid, title, location, text)
                VALUES (new.rowid, new.title, new.location, new.text);
            END
            """, database: database)

        if existingSchemaVersion < Self.schemaVersion {
            try execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')", database: database)
            try execute("PRAGMA user_version = \(Self.schemaVersion)", database: database)
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw SearchIndexError.executeFailed("database is closed")
        }

        try Self.execute(sql, database: database)
    }

    private static func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) }
                ?? database.sqliteErrorMessage
                ?? "execute failed with code \(result)"
            sqlite3_free(errorMessage)
            throw SearchIndexError.executeFailed(message)
        }
    }

    private static func userVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw SearchIndexError.prepareFailed(
                database.sqliteErrorMessage ?? "prepare failed with code \(prepareResult)"
            )
        }
        defer { sqlite3_finalize(statement) }

        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            return Int(sqlite3_column_int(statement, 0))
        case SQLITE_DONE:
            return 0
        default:
            throw SearchIndexError.stepFailed(database.sqliteErrorMessage ?? "step failed with code \(stepResult)")
        }
    }

    private func withStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let database else {
            throw SearchIndexError.prepareFailed("database is closed")
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw SearchIndexError.prepareFailed(
                database.sqliteErrorMessage ?? "prepare failed with code \(prepareResult)"
            )
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        guard result == SQLITE_OK else {
            throw SearchIndexError.bindFailed(database?.sqliteErrorMessage ?? "bind failed with code \(result)")
        }
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else {
            throw SearchIndexError.bindFailed(database?.sqliteErrorMessage ?? "bind failed with code \(result)")
        }
    }

    private func bindNull(at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else {
            throw SearchIndexError.bindFailed(database?.sqliteErrorMessage ?? "bind failed with code \(result)")
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SearchIndexError.stepFailed(database?.sqliteErrorMessage ?? "step failed with code \(result)")
        }
    }

    private static func hit(from statement: OpaquePointer) -> SearchIndexHit? {
        guard let id = statement.sqliteColumnText(0),
              let windowIDString = statement.sqliteColumnText(1),
              let workspaceIDString = statement.sqliteColumnText(2),
              let kindRawValue = statement.sqliteColumnText(4),
              let windowID = UUID(uuidString: windowIDString),
              let workspaceID = UUID(uuidString: workspaceIDString),
              let kind = GlobalSearchKind(rawValue: kindRawValue) else {
            return nil
        }

        let panelID = statement.sqliteColumnText(3).flatMap(UUID.init(uuidString:))
        let title = statement.sqliteColumnText(5) ?? ""
        let location = statement.sqliteColumnText(6) ?? ""
        let anchor = statement.sqliteColumnText(7) ?? ""
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        let snippet = statement.sqliteColumnText(9) ?? title
        let rank = sqlite3_column_double(statement, 10)

        return SearchIndexHit(
            id: id,
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            kind: kind,
            title: title,
            location: location,
            anchor: anchor,
            snippet: snippet,
            rank: rank,
            timestamp: timestamp
        )
    }

    static func queryTokens(for rawQuery: String) -> [String] {
        let tokens = rawQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }

        return tokens
    }

    private static func matchQuery(for rawQuery: String) -> String? {
        let tokens = queryTokens(for: rawQuery)
        guard !tokens.isEmpty else { return nil }

        return tokens.map { token in
            "\(token)*"
        }.joined(separator: " AND ")
    }

    private static func ensureParentDirectoryExists(for databaseURL: URL) throws {
        let parentURL = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
    }

    private static let sqliteTransient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )
}

extension URL {
    static var cmuxSearchDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("search.db", isDirectory: false)
    }
}
