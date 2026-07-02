import Foundation
import SQLite3

/// A Hermes session indexed from `state.db`. The `sessions` table carries a `cwd` column, so
/// callers can scope a lookup to a working directory (see
/// ``HermesAgentIndex/loadSessions(needle:cwdFilter:offset:limit:stateDBPath:)`` and
/// ``HermesAgentIndex/latestSessionID(cwd:stateDBPath:)``).
public struct HermesAgentIndexedSession: Equatable, Sendable {
    public let sessionId: String
    public let source: String
    public let title: String
    public let model: String?
    public let modified: Date
    public let preview: String?

    public init(
        sessionId: String,
        source: String,
        title: String,
        model: String?,
        modified: Date,
        preview: String?
    ) {
        self.sessionId = sessionId
        self.source = source
        self.title = title
        self.model = model
        self.modified = modified
        self.preview = preview
    }
}

public struct HermesAgentIndexResult: Equatable, Sendable {
    public let sessions: [HermesAgentIndexedSession]
    public let errors: [String]

    public init(sessions: [HermesAgentIndexedSession], errors: [String]) {
        self.sessions = sessions
        self.errors = errors
    }
}

public struct HermesAgentTranscriptTurn: Equatable, Sendable {
    public let role: String
    public let content: String
    public let toolName: String?

    public init(role: String, content: String, toolName: String?) {
        self.role = role
        self.content = content
        self.toolName = toolName
    }
}

public enum HermesAgentIndexError: Error, Equatable, Sendable {
    case missingDatabase
    case sqlite(String)
}

private struct HermesAgentDatabaseSnapshot {
    let databaseURL: URL
    private let directoryURL: URL

    init(databaseURL: URL, directoryURL: URL) {
        self.databaseURL = databaseURL
        self.directoryURL = directoryURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

public enum HermesAgentIndex {
    private static let contentJSONPrefix = "\u{0}json:"
    // Keep this list aligned with source kinds resumeCommand knows how to relaunch.
    private static let knownSources = ["cli", "tui"]

    public static func defaultStateDBPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let rawHome = normalized(env["HERMES_HOME"]) {
            return (expandedPath(rawHome, env: env) as NSString).appendingPathComponent("state.db")
        }
        let home = normalized(env["HOME"]) ?? NSHomeDirectory()
        return ((home as NSString).appendingPathComponent(".hermes") as NSString)
            .appendingPathComponent("state.db")
    }

    /// Loads Hermes `cli`/`tui` sessions from state.db, newest first.
    ///
    /// When `cwdFilter` is non-nil, only sessions whose `cwd` column equals the filter are
    /// returned. Matching is symlink-aware (the standardized path and its resolved form are both
    /// accepted) because Hermes records `os.getcwd()` — which resolves symlinks — while cmux may
    /// pass the logical launch directory. A row with a NULL/empty `cwd`, or a blank filter, never
    /// matches. Pass `nil` to list every `cli`/`tui` session regardless of directory.
    public static func loadSessions(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        stateDBPath: String = Self.defaultStateDBPath()
    ) -> HermesAgentIndexResult {
        guard limit > 0, offset >= 0 else {
            return HermesAgentIndexResult(sessions: [], errors: [])
        }
        let (_, overflow) = offset.addingReportingOverflow(limit)
        guard !overflow else {
            return HermesAgentIndexResult(sessions: [], errors: [])
        }
        let cwdCandidates = cwdFilter.map(cwdMatchCandidates(for:)) ?? []
        if cwdFilter != nil, cwdCandidates.isEmpty {
            return HermesAgentIndexResult(sessions: [], errors: [])
        }

        let snapshot: HermesAgentDatabaseSnapshot
        do {
            guard let madeSnapshot = try makeSnapshot(stateDBPath: stateDBPath, prefix: "cmux-hermes-agent-search") else {
                return HermesAgentIndexResult(sessions: [], errors: [])
            }
            snapshot = madeSnapshot
        } catch {
            return HermesAgentIndexResult(
                sessions: [],
                errors: ["Hermes Agent: cannot snapshot state.db (\(error.localizedDescription))"]
            )
        }
        defer { snapshot.remove() }

        do {
            return try withDatabase(snapshot.databaseURL.path) { db in
                try loadSessions(db: db, needle: needle, cwdCandidates: cwdCandidates, offset: offset, limit: limit)
            }
        } catch {
            return HermesAgentIndexResult(
                sessions: [],
                errors: ["Hermes Agent: cannot read state.db (\(errorDescription(error)))"]
            )
        }
    }

    /// Returns the id of the newest `cli`/`tui` session whose `cwd` matches `cwd`, or `nil` when
    /// there is no match (including no `cwd` metadata, or a missing/unreadable `state.db`).
    ///
    /// Unlike ``loadSessions(needle:cwdFilter:offset:limit:stateDBPath:)`` this reads the live
    /// `state.db` directly (read-only, WAL-safe) rather than copying it to a temp snapshot, so it
    /// stays cheap on the process-scan auto-resume path where `state.db` can be large. Matching is
    /// symlink-aware; because a wrong bind corrupts two sessions while a miss is recoverable, any
    /// ambiguity or error resolves to `nil`.
    public static func latestSessionID(
        cwd: String,
        stateDBPath: String = Self.defaultStateDBPath()
    ) -> String? {
        let cwdCandidates = cwdMatchCandidates(for: cwd)
        guard !cwdCandidates.isEmpty,
              FileManager.default.fileExists(atPath: stateDBPath) else {
            return nil
        }
        let resolved = try? withDatabase(stateDBPath) { db -> String? in
            try loadSessions(db: db, needle: "", cwdCandidates: cwdCandidates, offset: 0, limit: 1)
                .sessions.first?.sessionId
        }
        return resolved ?? nil
    }

    /// The `cwd` values a stored session `cwd` may equal for `cwd` to be considered a match: the
    /// standardized path and its symlink-resolved form. Empty for a blank input.
    static func cwdMatchCandidates(for cwd: String) -> [String] {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let standardized = (trimmed as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        var candidates: [String] = []
        for candidate in [standardized, resolved] where !candidate.isEmpty && !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    public static func loadTranscript(
        sessionId: String,
        limit: Int,
        stateDBPath: String = Self.defaultStateDBPath()
    ) throws -> [HermesAgentTranscriptTurn] {
        guard limit > 0 else { return [] }
        guard let snapshot = try makeSnapshot(stateDBPath: stateDBPath, prefix: "cmux-hermes-agent-preview") else {
            throw HermesAgentIndexError.missingDatabase
        }
        defer { snapshot.remove() }

        return try withDatabase(snapshot.databaseURL.path) { db in
            try loadTranscript(db: db, sessionId: sessionId, limit: limit)
        }
    }

    private static func loadSessions(
        db: OpaquePointer,
        needle: String,
        cwdCandidates: [String],
        offset: Int,
        limit: Int
    ) throws -> HermesAgentIndexResult {
        let trimmedNeedle = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasNeedle = !trimmedNeedle.isEmpty
        var sql = """
            SELECT
              s.id,
              s.source,
              COALESCE(s.title, '') AS title,
              s.model,
              COALESCE(MAX(m.timestamp), s.ended_at, s.started_at) AS last_active,
              (
                SELECT m2.content
                FROM messages m2
                WHERE m2.session_id = s.id
                  AND m2.role IN ('user', 'assistant')
                  AND COALESCE(m2.content, '') <> ''
                ORDER BY m2.timestamp DESC, m2.id DESC
                LIMIT 1
              ) AS preview
            FROM sessions s
            LEFT JOIN messages m ON m.session_id = s.id
            WHERE s.source IN (\(knownSources.map { "'\($0)'" }.joined(separator: ", ")))
            """
        // Bind order below MUST mirror the `?` order here: cwd candidates first, then needle.
        if !cwdCandidates.isEmpty {
            let placeholders = cwdCandidates.map { _ in "?" }.joined(separator: ", ")
            sql += "\n  AND s.cwd IN (\(placeholders))"
        }
        if hasNeedle {
            sql += """
                 AND (
                   LOWER(s.id) LIKE ?
                   OR LOWER(COALESCE(s.title, '')) LIKE ?
                   OR LOWER(COALESCE(s.model, '')) LIKE ?
                   OR EXISTS (
                     SELECT 1
                     FROM messages needle_messages
                     WHERE needle_messages.session_id = s.id
                       AND (
                         LOWER(COALESCE(needle_messages.content, '')) LIKE ?
                         OR LOWER(COALESCE(needle_messages.tool_name, '')) LIKE ?
                       )
                     LIMIT 1
                   )
                 )
                """
        }
        sql += """
            GROUP BY s.id
            ORDER BY last_active DESC
            LIMIT \(limit) OFFSET \(offset)
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw HermesAgentIndexError.sqlite(sqliteMessage(db) ?? "prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        let destructor = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        var bindIndex: Int32 = 1
        for candidate in cwdCandidates {
            guard sqlite3_bind_text(stmt, bindIndex, candidate, -1, destructor) == SQLITE_OK else {
                throw HermesAgentIndexError.sqlite(sqliteMessage(db) ?? "bind failed")
            }
            bindIndex += 1
        }
        if hasNeedle {
            let likePattern = "%\(trimmedNeedle)%"
            for _ in 0..<5 {
                guard sqlite3_bind_text(stmt, bindIndex, likePattern, -1, destructor) == SQLITE_OK else {
                    throw HermesAgentIndexError.sqlite(sqliteMessage(db) ?? "bind failed")
                }
                bindIndex += 1
            }
        }

        var sessions: [HermesAgentIndexedSession] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            let sessionId = sqliteText(stmt, 0) ?? ""
            guard !sessionId.isEmpty else {
                stepResult = sqlite3_step(stmt)
                continue
            }
            let source = sqliteText(stmt, 1) ?? "cli"
            let rawTitle = sqliteText(stmt, 2) ?? ""
            let model = sqliteText(stmt, 3)
            let modified = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let preview = decodedContentText(sqliteText(stmt, 5))
            let title = normalized(rawTitle) ?? firstLine(preview) ?? sessionId
            sessions.append(HermesAgentIndexedSession(
                sessionId: sessionId,
                source: source,
                title: title,
                model: model,
                modified: modified,
                preview: preview
            ))
            stepResult = sqlite3_step(stmt)
        }

        guard stepResult == SQLITE_DONE else {
            throw HermesAgentIndexError.sqlite(sqliteMessage(db) ?? "step failed")
        }
        return HermesAgentIndexResult(sessions: sessions, errors: [])
    }

    private static func loadTranscript(
        db: OpaquePointer,
        sessionId: String,
        limit: Int
    ) throws -> [HermesAgentTranscriptTurn] {
        let sql = """
            SELECT role, content, tool_name, tool_calls
            FROM messages
            WHERE session_id = ?
            ORDER BY timestamp, id
            LIMIT \(limit)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw HermesAgentIndexError.sqlite(sqliteMessage(db) ?? "prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        let destructor = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, sessionId, -1, destructor) == SQLITE_OK else {
            throw HermesAgentIndexError.sqlite(sqliteMessage(db) ?? "bind failed")
        }

        var turns: [HermesAgentTranscriptTurn] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            let role = sqliteText(stmt, 0) ?? "event"
            let content = decodedContentText(sqliteText(stmt, 1))
            let toolName = sqliteText(stmt, 2)
            let toolCalls = decodedContentText(sqliteText(stmt, 3))
            let text = [content, toolCalls]
                .compactMap { normalized($0) }
                .joined(separator: "\n\n")
            if !text.isEmpty {
                turns.append(HermesAgentTranscriptTurn(role: role, content: text, toolName: toolName))
            }
            stepResult = sqlite3_step(stmt)
        }

        guard stepResult == SQLITE_DONE else {
            throw HermesAgentIndexError.sqlite(sqliteMessage(db) ?? "step failed")
        }
        return turns
    }

    private static func makeSnapshot(stateDBPath: String, prefix: String) throws -> HermesAgentDatabaseSnapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stateDBPath) else { return nil }

        let snapshotDir = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let snapshotDB = snapshotDir.appendingPathComponent("state.db", isDirectory: false)
        do {
            try fileManager.copyItem(atPath: stateDBPath, toPath: snapshotDB.path)
            for sidecar in ["-wal", "-shm"] {
                let source = stateDBPath + sidecar
                let destination = snapshotDB.path + sidecar
                if fileManager.fileExists(atPath: source) {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                }
            }
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }
        return HermesAgentDatabaseSnapshot(databaseURL: snapshotDB, directoryURL: snapshotDir)
    }

    private static func withDatabase<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            let message = sqliteMessage(db) ?? "open failed with code \(openResult)"
            sqlite3_close(db)
            throw HermesAgentIndexError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        _ = sqlite3_busy_timeout(db, 50)
        return try body(db)
    }

    private static func decodedContentText(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.hasPrefix(contentJSONPrefix) {
            let payload = String(value.dropFirst(contentJSONPrefix.count))
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                return value
            }
            return renderedContent(object)
        }
        return value
    }

    private static func renderedContent(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let array = value as? [Any] {
            let parts = array.compactMap(renderedContent)
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        for key in ["text", "content", "output", "result", "message"] {
            if let value = object[key], let rendered = renderedContent(value) {
                return rendered
            }
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func firstLine(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        return value.components(separatedBy: .newlines).first.map { String($0.prefix(120)) }
    }

    private static func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(stmt, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
    }

    private static func sqliteMessage(_ db: OpaquePointer?) -> String? {
        guard let db, let cString = sqlite3_errmsg(db) else { return nil }
        return String(cString: cString)
    }

    private static func errorDescription(_ error: Error) -> String {
        if let error = error as? HermesAgentIndexError {
            switch error {
            case .missingDatabase:
                return "missing database"
            case let .sqlite(message):
                return message
            }
        }
        return error.localizedDescription
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func expandedPath(_ path: String, env: [String: String]) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else {
            return NSString(string: trimmed).expandingTildeInPath
        }
        let home = normalized(env["HOME"]) ?? NSHomeDirectory()
        guard trimmed != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
    }
}
