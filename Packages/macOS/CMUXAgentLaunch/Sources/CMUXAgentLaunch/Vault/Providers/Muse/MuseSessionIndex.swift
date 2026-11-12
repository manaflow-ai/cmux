import Foundation
import SQLite3

/// A top-level Muse Code session read from Muse's `session-index.db`.
public struct MuseIndexedSession: Equatable, Sendable {
    public let sessionId: String
    public let title: String
    public let cwd: String?
    public let gitBranch: String?
    public let modified: Date

    public init(sessionId: String, title: String, cwd: String?, gitBranch: String?, modified: Date) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.modified = modified
    }
}

public struct MuseSessionIndexResult: Equatable, Sendable {
    public let sessions: [MuseIndexedSession]
    public let errors: [String]

    public init(sessions: [MuseIndexedSession], errors: [String]) {
        self.sessions = sessions
        self.errors = errors
    }
}

/// Reads Muse Code's own session index without writing to it.
///
/// Muse keeps one row per session in `$XDG_DATA_HOME/muse/session-index.db`
/// (default `~/.local/share/muse`). Child sessions (subagents and reminder
/// workers) carry a parent id or a non-root kind and are never resumable on
/// their own, and a session with no submitted prompt has nothing to resume.
public struct MuseSessionIndex: Sendable {
    /// The `session-index.db` this reader opens.
    public let indexDatabasePath: String

    /// Reads the index at an explicit path.
    public init(indexDatabasePath: String) {
        self.indexDatabasePath = indexDatabasePath
    }

    /// Reads the index in Muse's data directory for `env`.
    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.init(indexDatabasePath: Self.indexDatabasePath(
            dataDirectory: Self.defaultDataDirectory(env: env, homeDirectory: homeDirectory)
        ))
    }

    /// Muse's data directory, honoring `XDG_DATA_HOME` like the Muse CLI does.
    public static func defaultDataDirectory(
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        if let xdg = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            return ((xdg as NSString).expandingTildeInPath as NSString).appendingPathComponent("muse")
        }
        return (homeDirectory as NSString).appendingPathComponent(".local/share/muse")
    }

    public static func indexDatabasePath(dataDirectory: String) -> String {
        (dataDirectory as NSString).appendingPathComponent("session-index.db")
    }

    /// Loads resumable top-level sessions, newest first.
    public func loadSessions(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) -> MuseSessionIndexResult {
        let indexDBPath = indexDatabasePath
        guard limit > 0, offset >= 0, !offset.addingReportingOverflow(limit).overflow else {
            return MuseSessionIndexResult(sessions: [], errors: [])
        }
        let snapshot: HermesAgentDatabaseSnapshot
        do {
            guard let madeSnapshot = try HermesAgentIndex.makeSnapshot(
                stateDBPath: indexDBPath,
                prefix: "cmux-muse-session-index"
            ) else {
                return MuseSessionIndexResult(sessions: [], errors: [])
            }
            snapshot = madeSnapshot
        } catch {
            return MuseSessionIndexResult(
                sessions: [],
                errors: ["Muse Code: cannot snapshot session-index.db (\(error.localizedDescription))"]
            )
        }
        defer { snapshot.remove() }

        do {
            return try HermesAgentIndex.withDatabase(snapshot.databaseURL.path) { db in
                try Self.loadSessions(db: db, needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit)
            }
        } catch {
            let message: String
            if case let HermesAgentIndexError.sqlite(detail) = error {
                message = detail
            } else {
                message = error.localizedDescription
            }
            return MuseSessionIndexResult(
                sessions: [],
                errors: ["Muse Code: cannot read session-index.db (\(message))"]
            )
        }
    }

    private static func loadSessions(
        db: OpaquePointer,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) throws -> MuseSessionIndexResult {
        let trimmedNeedle = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cwdCandidates = cwdFilter.map(cwdMatchCandidates(for:)) ?? []
        var sql = """
            SELECT
              session_id,
              COALESCE(NULLIF(TRIM(session_name), ''), NULLIF(TRIM(title), ''), NULLIF(TRIM(first_user_prompt), '')) AS display_title,
              workspace_root,
              git_branch,
              updated_at_us
            FROM sessions
            WHERE msp_parent_session_id IS NULL
              AND (msp_kind IS NULL OR msp_kind = 'root')
              AND COALESCE(prompt_count, 0) > 0
            """
        if !cwdCandidates.isEmpty {
            sql += "\n  AND workspace_root IN (\(cwdCandidates.map { _ in "?" }.joined(separator: ", ")))"
        }
        if !trimmedNeedle.isEmpty {
            sql += """

                  AND (
                    LOWER(session_id) LIKE ?
                    OR LOWER(COALESCE(title, '')) LIKE ?
                    OR LOWER(COALESCE(session_name, '')) LIKE ?
                    OR LOWER(COALESCE(first_user_prompt, '')) LIKE ?
                    OR LOWER(COALESCE(search_text, '')) LIKE ?
                  )
                """
        }
        sql += "\nORDER BY updated_at_us DESC\nLIMIT \(limit) OFFSET \(offset)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw HermesAgentIndexError.sqlite(HermesAgentIndex.sqliteMessage(db) ?? "prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        let destructor = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        var bindIndex: Int32 = 1
        let bindings = cwdCandidates + (trimmedNeedle.isEmpty ? [] : Array(repeating: "%\(trimmedNeedle)%", count: 5))
        for value in bindings {
            guard sqlite3_bind_text(stmt, bindIndex, value, -1, destructor) == SQLITE_OK else {
                throw HermesAgentIndexError.sqlite(HermesAgentIndex.sqliteMessage(db) ?? "bind failed")
            }
            bindIndex += 1
        }

        var sessions: [MuseIndexedSession] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            if let sessionId = HermesAgentIndex.normalized(HermesAgentIndex.sqliteText(stmt, 0)) {
                let title = HermesAgentIndex.normalized(HermesAgentIndex.sqliteText(stmt, 1))
                    .map { String($0.components(separatedBy: .newlines).first?.prefix(120) ?? "") }
                    ?? sessionId
                let updatedMicros = sqlite3_column_int64(stmt, 4)
                sessions.append(MuseIndexedSession(
                    sessionId: sessionId,
                    title: title,
                    cwd: HermesAgentIndex.normalized(HermesAgentIndex.sqliteText(stmt, 2)),
                    gitBranch: HermesAgentIndex.normalized(HermesAgentIndex.sqliteText(stmt, 3)),
                    modified: Date(timeIntervalSince1970: Double(updatedMicros) / 1_000_000)
                ))
            }
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw HermesAgentIndexError.sqlite(HermesAgentIndex.sqliteMessage(db) ?? "step failed")
        }
        return MuseSessionIndexResult(sessions: sessions, errors: [])
    }

    /// Muse records the canonical workspace path, so `/tmp/...` is stored as
    /// `/private/tmp/...`; match both spellings of the filter.
    static func cwdMatchCandidates(for cwd: String) -> [String] {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let standardized = (trimmed as NSString).standardizingPath
        // `realpath` keeps the `/private` prefix that `resolvingSymlinksInPath` strips.
        let resolved = realpath(standardized, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        var candidates: [String] = []
        for candidate in [trimmed, standardized, resolved].compactMap({ $0 }) where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }
}
