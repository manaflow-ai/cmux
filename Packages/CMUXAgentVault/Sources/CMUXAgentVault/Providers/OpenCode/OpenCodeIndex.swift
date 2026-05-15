import Foundation
import SQLite3

public nonisolated struct OpenCodeIndexedSession: Equatable, Sendable {
    public let sessionId: String
    public let title: String
    public let directory: String?
    public let modified: Date
    public let providerModel: String?
    public let agentName: String?

    public init(
        sessionId: String,
        title: String,
        directory: String?,
        modified: Date,
        providerModel: String?,
        agentName: String?
    ) {
        self.sessionId = sessionId
        self.title = title
        self.directory = directory
        self.modified = modified
        self.providerModel = providerModel
        self.agentName = agentName
    }
}

public nonisolated struct OpenCodeIndexResult: Equatable, Sendable {
    public let sessions: [OpenCodeIndexedSession]
    public let errors: [String]

    public init(sessions: [OpenCodeIndexedSession], errors: [String]) {
        self.sessions = sessions
        self.errors = errors
    }
}

private enum OpenCodeIndexError: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case sqlite(String)
}

public enum OpenCodeDatabaseSnapshot {
    public nonisolated struct Snapshot: Sendable {
        public let databaseURL: URL
        private let directoryURL: URL

        init(databaseURL: URL, directoryURL: URL) {
            self.databaseURL = databaseURL
            self.directoryURL = directoryURL
        }

        public func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    public nonisolated static func defaultDatabasePath(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let home = normalized(env["HOME"]) ?? NSHomeDirectory()
        return (((home as NSString).appendingPathComponent(".local/share/opencode")) as NSString)
            .appendingPathComponent("opencode.db")
    }

    public nonisolated static func make(prefix: String) throws -> Snapshot? {
        try make(prefix: prefix, databasePath: defaultDatabasePath())
    }

    public nonisolated static func make(prefix: String, databasePath: String) throws -> Snapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databasePath) else { return nil }

        let snapshotDir = fileManager.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let snapshotDB = snapshotDir.appendingPathComponent("opencode.db", isDirectory: false)
        do {
            try fileManager.copyItem(atPath: databasePath, toPath: snapshotDB.path)
            for sidecar in ["-wal", "-shm"] {
                let source = databasePath + sidecar
                let destination = snapshotDB.path + sidecar
                if fileManager.fileExists(atPath: source) {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                }
            }
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }

        return Snapshot(databaseURL: snapshotDB, directoryURL: snapshotDir)
    }
}

public enum OpenCodeIndex {
    public nonisolated static func loadSessions(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        databasePath: String = OpenCodeDatabaseSnapshot.defaultDatabasePath()
    ) -> OpenCodeIndexResult {
        guard limit > 0, offset >= 0 else {
            return OpenCodeIndexResult(sessions: [], errors: [])
        }

        let snapshot: OpenCodeDatabaseSnapshot.Snapshot
        do {
            guard let madeSnapshot = try OpenCodeDatabaseSnapshot.make(
                prefix: "cmux-opencode-search",
                databasePath: databasePath
            ) else {
                return OpenCodeIndexResult(sessions: [], errors: [])
            }
            snapshot = madeSnapshot
        } catch {
            let message = String(
                localized: "sessionIndex.error.openCodeSnapshot",
                defaultValue: "OpenCode session history is temporarily unavailable."
            )
            return OpenCodeIndexResult(
                sessions: [],
                errors: [message]
            )
        }
        defer { snapshot.remove() }

        do {
            return try withDatabase(snapshot.databaseURL.path) { db in
                try loadSessions(db: db, needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit)
            }
        } catch {
            if case OpenCodeIndexError.unsupportedSchema = error {
                let message = String(
                    localized: "sessionIndex.error.openCodeSchemaUnsupported",
                    defaultValue: "OpenCode session history is unavailable in this version."
                )
                return OpenCodeIndexResult(
                    sessions: [],
                    errors: [message]
                )
            }
            let message = String(
                localized: "sessionIndex.error.openCodeRead",
                defaultValue: "OpenCode session history could not be read."
            )
            return OpenCodeIndexResult(
                sessions: [],
                errors: [message]
            )
        }
    }

    private static func loadSessions(
        db: OpaquePointer,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) throws -> OpenCodeIndexResult {
        let trimmedNeedle = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sql = """
            SELECT s.id, s.title, s.directory, s.time_updated, (
                SELECT data FROM message
                WHERE session_id = s.id AND data LIKE '%"role":"assistant"%'
                ORDER BY time_created DESC LIMIT 1
            ) AS last_assistant
            FROM session s
            """
        var conditions: [String] = []
        if !trimmedNeedle.isEmpty {
            conditions.append("(LOWER(s.title) LIKE ? OR LOWER(s.directory) LIKE ?)")
        }
        if cwdFilter != nil {
            conditions.append("s.directory = ?")
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY s.time_updated DESC LIMIT \(limit) OFFSET \(offset)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw OpenCodeIndexError.unsupportedSchema(sqliteMessage(db) ?? "prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        let destructor = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        var bindIndex: Int32 = 1
        if !trimmedNeedle.isEmpty {
            let likePattern = "%\(trimmedNeedle)%"
            guard sqlite3_bind_text(stmt, bindIndex, likePattern, -1, destructor) == SQLITE_OK else {
                throw OpenCodeIndexError.sqlite(sqliteMessage(db) ?? "bind failed")
            }
            bindIndex += 1
            guard sqlite3_bind_text(stmt, bindIndex, likePattern, -1, destructor) == SQLITE_OK else {
                throw OpenCodeIndexError.sqlite(sqliteMessage(db) ?? "bind failed")
            }
            bindIndex += 1
        }
        if let cwdFilter {
            guard sqlite3_bind_text(stmt, bindIndex, cwdFilter, -1, destructor) == SQLITE_OK else {
                throw OpenCodeIndexError.sqlite(sqliteMessage(db) ?? "bind failed")
            }
        }

        var sessions: [OpenCodeIndexedSession] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            let sessionId = sqliteText(stmt, 0) ?? ""
            guard !sessionId.isEmpty else {
                stepResult = sqlite3_step(stmt)
                continue
            }
            let title = sqliteText(stmt, 1) ?? ""
            let directory = sqliteText(stmt, 2)
            let modified = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3)) / 1000.0)
            let (providerModel, agentName) = parseAssistant(sqliteText(stmt, 4))
            sessions.append(OpenCodeIndexedSession(
                sessionId: sessionId,
                title: title,
                directory: directory,
                modified: modified,
                providerModel: providerModel,
                agentName: agentName
            ))
            stepResult = sqlite3_step(stmt)
        }

        guard stepResult == SQLITE_DONE else {
            throw OpenCodeIndexError.sqlite(sqliteMessage(db) ?? "step failed")
        }
        return OpenCodeIndexResult(sessions: sessions, errors: [])
    }

    private static func withDatabase<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            let message = sqliteMessage(db) ?? "open failed with code \(openResult)"
            sqlite3_close(db)
            throw OpenCodeIndexError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        _ = sqlite3_busy_timeout(db, 50)
        return try body(db)
    }

    private static func parseAssistant(_ raw: String?) -> (String?, String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let modelID = obj["modelID"] as? String
        let providerID = obj["providerID"] as? String
        let agentName = obj["agent"] as? String
        let providerModel: String? = {
            switch (providerID, modelID) {
            case let (p?, m?) where !p.isEmpty && !m.isEmpty: return "\(p)/\(m)"
            case let (_, m?) where !m.isEmpty: return m
            default: return nil
            }
        }()
        return (providerModel, agentName?.isEmpty == false ? agentName : nil)
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

}

private func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}
