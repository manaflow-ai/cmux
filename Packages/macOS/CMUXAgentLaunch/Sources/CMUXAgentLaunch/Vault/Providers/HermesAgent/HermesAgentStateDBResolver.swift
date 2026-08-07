import Foundation
import SQLite3

/// Resolves the session owned by a live Hermes CLI/TUI process from Hermes's persisted state.
///
/// Hermes mints session IDs internally, so a fresh process has no ID in argv. The only durable
/// correlation available in Hermes 0.19.0 is `sessions.cwd` in `state.db`. This resolver deliberately
/// fails closed: it returns an ID only when exactly one active CLI/TUI row matches the process cwd.
/// A missed binding is recoverable on the next hook or scan; a guessed binding can restore the wrong
/// conversation into a pane.
public struct HermesAgentStateDBResolver: Sendable {
    private let knownSourcesSQL = "'cli', 'tui'"

    /// Creates a resolver for Hermes's persisted SQLite session store.
    public init() {}

    /// Returns the sole active Hermes CLI/TUI session matching a working directory.
    ///
    /// - Parameters:
    ///   - cwd: The working directory captured from the live Hermes process.
    ///   - stateDBPath: The path to Hermes's `state.db`.
    /// - Returns: The matching session ID, or `nil` when the database cannot prove a unique match.
    public func uniqueActiveSessionID(cwd: String, stateDBPath: String) -> String? {
        let cwdCandidates = cwdMatchCandidates(for: cwd)
        guard !cwdCandidates.isEmpty else {
            return nil
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(stateDBPath, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        guard sessionsHaveCwdColumn(database) else { return nil }
        let placeholders = cwdCandidates.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT id
            FROM sessions
            WHERE source IN (\(knownSourcesSQL))
              AND cwd IN (\(placeholders))
              AND ended_at IS NULL
            LIMIT 2
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let destructor = unsafeBitCast(
            OpaquePointer(bitPattern: -1),
            to: sqlite3_destructor_type.self
        )
        for (index, candidate) in cwdCandidates.enumerated() {
            guard sqlite3_bind_text(
                statement,
                Int32(index + 1),
                candidate,
                -1,
                destructor
            ) == SQLITE_OK else {
                return nil
            }
        }

        var soleSessionID: String?
        var rowCount = 0
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            rowCount += 1
            guard rowCount == 1 else { return nil }
            soleSessionID = sqliteText(statement, column: 0)
            stepResult = sqlite3_step(statement)
        }

        // SQLITE_BUSY/corruption after the first row must not masquerade as a unique result.
        guard stepResult == SQLITE_DONE,
              rowCount == 1,
              let soleSessionID,
              !soleSessionID.isEmpty else {
            return nil
        }
        return soleSessionID
    }

    /// Canonical identity used to group live panes before querying `state.db`.
    ///
    /// Hermes records `os.getcwd()`, which resolves symlinks. cmux can retain the logical path a
    /// user launched through, so grouping and lookup both consider the standardized and real paths.
    public func canonicalCwd(_ cwd: String) -> String? {
        cwdMatchCandidates(for: cwd).last
    }

    func cwdMatchCandidates(for cwd: String) -> [String] {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let standardized = (trimmed as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        var candidates: [String] = []
        for candidate in [standardized, resolved]
        where !candidate.isEmpty && !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    func sessionsHaveCwdColumn(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(sessions)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }

        var foundCwd = false
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if sqliteText(statement, column: 1) == "cwd" {
                foundCwd = true
            }
            stepResult = sqlite3_step(statement)
        }
        return stepResult == SQLITE_DONE && foundCwd
    }

    private func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, column) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
    }
}
