import Foundation
import SQLite3

/// Provides Hermes `state.db` schema and cwd normalization for Vault indexing.
struct HermesAgentStateDBResolver: Sendable {
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
