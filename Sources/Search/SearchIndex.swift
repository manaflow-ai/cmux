import Foundation
import SQLite3

enum GlobalSearchKind: String, Codable, Sendable {
    case browser
    case markdown
    case terminal
    case title

    var localizedLabel: String {
        switch self {
        case .browser:
            return String(localized: "globalSearch.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "globalSearch.kind.markdown", defaultValue: "Markdown")
        case .terminal:
            return String(localized: "globalSearch.kind.terminal", defaultValue: "Terminal")
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

    static func terminalLineChunkStableID(panelID: UUID, startLineNumber: Int) -> String {
        panelStableID(panelID: panelID, kind: .terminal, subtype: "line:\(startLineNumber)")
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
            let message = Self.sqliteMessage(openedDatabase) ?? "unknown SQLite open failure"
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

    func deletePanelDocuments(panelID: UUID, kind: GlobalSearchKind) throws {
        try withStatement("DELETE FROM chunks WHERE panel_id = ?1 AND kind = ?2") { statement in
            try bind(panelID.uuidString, at: 1, in: statement)
            try bind(kind.rawValue, at: 2, in: statement)
            try stepDone(statement)
        }
    }

    func replacePanelDocuments(
        panelID: UUID,
        kind: GlobalSearchKind,
        with documents: [SearchIndexDocument]
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try deletePanelDocuments(panelID: panelID, kind: kind)
            for document in documents {
                try upsert(document)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
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

        let ftsHits: [SearchIndexHit]
        if let matchQuery = Self.matchQuery(for: trimmed) {
            ftsHits = try withStatement(sql) { statement in
                try bind(matchQuery, at: 1, in: statement)
                let limitBindResult = sqlite3_bind_int64(statement, 2, sqlite3_int64(limit))
                guard limitBindResult == SQLITE_OK else {
                    throw SearchIndexError.bindFailed(
                        Self.sqliteMessage(database) ?? "bind failed with code \(limitBindResult)"
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
                        throw SearchIndexError.stepFailed(Self.sqliteMessage(database) ?? "step failed with code \(stepResult)")
                    }
                }
            }
        } else {
            ftsHits = []
        }

        guard ftsHits.count < limit else { return ftsHits }
        let excludedIDs = Set(ftsHits.map(\.id))
        let fuzzyHits = try fuzzySearch(
            trimmed,
            excludingIDs: excludedIDs,
            limit: limit - ftsHits.count
        )
        return Array((ftsHits + fuzzyHits).prefix(limit))
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
                ?? Self.sqliteMessage(database)
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
                sqliteMessage(database) ?? "prepare failed with code \(prepareResult)"
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
            throw SearchIndexError.stepFailed(sqliteMessage(database) ?? "step failed with code \(stepResult)")
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
                Self.sqliteMessage(database) ?? "prepare failed with code \(prepareResult)"
            )
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        guard result == SQLITE_OK else {
            throw SearchIndexError.bindFailed(Self.sqliteMessage(database) ?? "bind failed with code \(result)")
        }
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else {
            throw SearchIndexError.bindFailed(Self.sqliteMessage(database) ?? "bind failed with code \(result)")
        }
    }

    private func bindNull(at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else {
            throw SearchIndexError.bindFailed(Self.sqliteMessage(database) ?? "bind failed with code \(result)")
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SearchIndexError.stepFailed(Self.sqliteMessage(database) ?? "step failed with code \(result)")
        }
    }

    private static func hit(from statement: OpaquePointer) -> SearchIndexHit? {
        guard let id = sqliteText(statement, 0),
              let windowIDString = sqliteText(statement, 1),
              let workspaceIDString = sqliteText(statement, 2),
              let kindRawValue = sqliteText(statement, 4),
              let windowID = UUID(uuidString: windowIDString),
              let workspaceID = UUID(uuidString: workspaceIDString),
              let kind = GlobalSearchKind(rawValue: kindRawValue) else {
            return nil
        }

        let panelID = sqliteText(statement, 3).flatMap(UUID.init(uuidString:))
        let title = sqliteText(statement, 5) ?? ""
        let location = sqliteText(statement, 6) ?? ""
        let anchor = sqliteText(statement, 7) ?? ""
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        let snippet = sqliteText(statement, 9) ?? title
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

    private struct StoredSearchDocument {
        let id: String
        let windowID: UUID
        let workspaceID: UUID
        let panelID: UUID?
        let kind: GlobalSearchKind
        let title: String
        let location: String
        let anchor: String
        let timestamp: Date
        let text: String
    }

    private func fuzzySearch(
        _ rawQuery: String,
        excludingIDs excludedIDs: Set<String>,
        limit: Int
    ) throws -> [SearchIndexHit] {
        guard limit > 0 else { return [] }
        let fuzzyQuery = Self.normalizedFuzzyQuery(rawQuery)
        guard !fuzzyQuery.isEmpty else { return [] }

        let sql = """
            SELECT
                id,
                window_id,
                workspace_id,
                panel_id,
                kind,
                title,
                location,
                anchor,
                ts,
                text
            FROM chunks
            ORDER BY ts DESC
            """

        let matches: [SearchIndexHit] = try withStatement(sql) { statement in
            var hits: [SearchIndexHit] = []
            while true {
                let stepResult = sqlite3_step(statement)
                switch stepResult {
                case SQLITE_ROW:
                    guard let document = Self.storedDocument(from: statement),
                          !excludedIDs.contains(document.id) else {
                        continue
                    }
                    let searchable = [
                        document.title,
                        document.location,
                        document.text
                    ].joined(separator: "\n")
                    guard let score = Self.fuzzyScore(query: fuzzyQuery, candidate: searchable) else {
                        continue
                    }
                    hits.append(
                        SearchIndexHit(
                            id: document.id,
                            windowID: document.windowID,
                            workspaceID: document.workspaceID,
                            panelID: document.panelID,
                            kind: document.kind,
                            title: document.title,
                            location: document.location,
                            anchor: document.anchor,
                            snippet: Self.fuzzySnippet(query: rawQuery, text: document.text, fallback: document.title),
                            rank: 10_000 + score,
                            timestamp: document.timestamp
                        )
                    )
                case SQLITE_DONE:
                    return hits
                default:
                    throw SearchIndexError.stepFailed(Self.sqliteMessage(database) ?? "step failed with code \(stepResult)")
                }
            }
        }

        return matches
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.timestamp > $1.timestamp
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func storedDocument(from statement: OpaquePointer) -> StoredSearchDocument? {
        guard let id = sqliteText(statement, 0),
              let windowIDString = sqliteText(statement, 1),
              let workspaceIDString = sqliteText(statement, 2),
              let kindRawValue = sqliteText(statement, 4),
              let windowID = UUID(uuidString: windowIDString),
              let workspaceID = UUID(uuidString: workspaceIDString),
              let kind = GlobalSearchKind(rawValue: kindRawValue) else {
            return nil
        }

        return StoredSearchDocument(
            id: id,
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: sqliteText(statement, 3).flatMap(UUID.init(uuidString:)),
            kind: kind,
            title: sqliteText(statement, 5) ?? "",
            location: sqliteText(statement, 6) ?? "",
            anchor: sqliteText(statement, 7) ?? "",
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            text: sqliteText(statement, 9) ?? ""
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

    static func normalizedFuzzyQuery(_ rawQuery: String) -> String {
        rawQuery
            .lowercased()
            .unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
    }

    static func fuzzyScore(query: String, candidate: String) -> Double? {
        fuzzyMatch(query: query, candidate: candidate)?.score
    }

    static func fuzzyMatchedRange(query: String, in candidate: String) -> Range<String.Index>? {
        let fuzzyQuery = normalizedFuzzyQuery(query)
        guard let match = fuzzyMatch(query: fuzzyQuery, candidate: candidate),
              let first = match.positions.first,
              let last = match.positions.last else {
            return nil
        }

        let scalars = candidate.unicodeScalars
        guard let startScalar = scalars.index(scalars.startIndex, offsetBy: first, limitedBy: scalars.endIndex),
              let lastScalar = scalars.index(scalars.startIndex, offsetBy: last, limitedBy: scalars.endIndex) else {
            return nil
        }
        let endScalar = scalars.index(after: lastScalar)
        let start = String.Index(startScalar, within: candidate) ?? candidate.startIndex
        let end = String.Index(endScalar, within: candidate) ?? candidate.endIndex
        return start..<end
    }

    private struct FuzzyMatch {
        let score: Double
        let positions: [Int]
    }

    private static func fuzzyMatch(query: String, candidate: String) -> FuzzyMatch? {
        let queryScalars = Array(query.lowercased().unicodeScalars)
        let candidateScalars = Array(candidate.lowercased().unicodeScalars)
        guard !queryScalars.isEmpty, !candidateScalars.isEmpty else { return nil }

        var bestPositions = Array<[Int]?>(repeating: nil, count: queryScalars.count)

        for (candidateIndex, candidateScalar) in candidateScalars.enumerated() {
            for queryIndex in stride(from: queryScalars.count - 1, through: 0, by: -1) {
                guard queryScalars[queryIndex] == candidateScalar else { continue }

                let positions: [Int]
                if queryIndex == 0 {
                    positions = [candidateIndex]
                } else {
                    guard let previousPositions = bestPositions[queryIndex - 1] else {
                        continue
                    }
                    positions = previousPositions + [candidateIndex]
                }

                if isBetterFuzzyPrefix(positions, than: bestPositions[queryIndex]) {
                    bestPositions[queryIndex] = positions
                }
            }
        }

        let lastQueryIndex = queryScalars.count - 1
        guard let positions = bestPositions[lastQueryIndex] else {
            return nil
        }

        var score = Double(positions.last ?? 0) * 0.001
        score += Double((positions.last ?? 0) - (positions.first ?? 0)) * 2
        for index in positions.indices.dropFirst() {
            let gap = positions[index] - positions[index - 1] - 1
            if gap == 0 {
                score -= 1
            }
        }
        return FuzzyMatch(
            score: score,
            positions: positions
        )
    }

    private static func isBetterFuzzyPrefix(_ candidate: [Int], than current: [Int]?) -> Bool {
        guard let current,
              let candidateFirst = candidate.first,
              let candidateLast = candidate.last,
              let currentFirst = current.first,
              let currentLast = current.last else {
            return true
        }

        let candidateSpan = candidateLast - candidateFirst
        let currentSpan = currentLast - currentFirst
        if candidateSpan != currentSpan {
            return candidateSpan < currentSpan
        }
        return candidateFirst > currentFirst
    }

    private static func fuzzySnippet(query: String, text: String, fallback: String) -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSource = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return fallbackSource }

        let lowercasedSource = source.lowercased()
        if let token = queryTokens(for: query).first(where: { lowercasedSource.contains($0) }),
           let range = lowercasedSource.range(of: token) {
            return snippet(from: source, around: range.lowerBound)
        }

        let fuzzyQuery = normalizedFuzzyQuery(query)
        if !fuzzyQuery.isEmpty,
           let range = fuzzyMatchedRange(query: fuzzyQuery, in: source) {
            return snippet(from: source, around: range.lowerBound)
        }

        return snippet(from: source, around: source.startIndex)
    }

    private static func snippet(from text: String, around index: String.Index, radius: Int = 90) -> String {
        let lineStart = text[..<index].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let start = text.distance(from: lineStart, to: index) <= radius
            ? lineStart
            : (text.index(index, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex)
        let end = text.index(index, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end])
        if start > text.startIndex {
            snippet = "..." + snippet
        }
        if end < text.endIndex {
            snippet += "..."
        }
        return snippet
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

    private static func sqliteText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func sqliteMessage(_ database: OpaquePointer?) -> String? {
        guard let database, let cString = sqlite3_errmsg(database) else { return nil }
        return String(cString: cString)
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
