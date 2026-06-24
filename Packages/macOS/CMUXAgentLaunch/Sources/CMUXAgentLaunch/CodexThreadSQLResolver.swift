public import Foundation
public import CmuxFoundation
import SQLite3

/// Reads Codex session metadata directly from Codex's own `state_5.sqlite`
/// (`threads` table), where Codex pre-extracts cwd, title, model, branch,
/// approval, sandbox, effort, and rollout path per session, so a search never
/// has to open the rollout `.jsonl` files for the metadata it already holds.
///
/// This is the SQLite-read core of Codex session search. It owns no app state
/// and builds zero session-entry: it returns ``CodexThreadRecord`` values and
/// the app maps them onto its own session-entry type. Resolution snapshots the
/// live database read-only (via ``OpenCodeDatabaseSnapshot``) so it never
/// contends with the running Codex process.
///
/// The injected ``RipgrepFileScanner`` pre-filters rollout files by needle for
/// the content-match path; the injected `searchMaxFiles`, `FileManager`,
/// `dbPath`, and `sessionsRoot` keep the resolver decoupled and testable against
/// a scoped filesystem.
public struct CodexThreadSQLResolver {
    private let ripgrepScanner: RipgrepFileScanner
    private let searchMaxFiles: Int
    private let fileManager: FileManager
    private let dbPath: String
    private let sessionsRoot: String

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - ripgrepScanner: Pre-filters rollout `.jsonl` files by needle and reads
    ///     bounded file heads for the content-match path.
    ///   - searchMaxFiles: Hard cap on `threads` rows fetched when searching, so a
    ///     heavy user's full history is never fully read on a single scan.
    ///   - fileManager: Filesystem used to probe for the database; defaults to `.default`.
    ///   - dbPath: Path to Codex's `state_5.sqlite`; defaults to `~/.codex/state_5.sqlite`.
    ///   - sessionsRoot: Root Codex writes rollouts under; defaults to
    ///     `~/.codex/sessions`.
    public init(
        ripgrepScanner: RipgrepFileScanner,
        searchMaxFiles: Int,
        fileManager: FileManager = .default,
        dbPath: String = ("~/.codex/state_5.sqlite" as NSString).expandingTildeInPath,
        sessionsRoot: String = (CodexSessionResolver().codexSessionsRoot(env: [:]) as NSString).standardizingPath
    ) {
        self.ripgrepScanner = ripgrepScanner
        self.searchMaxFiles = searchMaxFiles
        self.fileManager = fileManager
        self.dbPath = dbPath
        self.sessionsRoot = sessionsRoot
    }

    /// Reads matching Codex `threads` rows. Returns `nil` when `state_5.sqlite`
    /// does not exist or its schema is unsupported (so the caller can fall back to
    /// the disk scan), an empty array when nothing matches.
    ///
    /// - When `needle` is empty: returns the most-recent `limit` rows (skipping
    ///   `offset`), filtered by `cwdFilter` in SQL.
    /// - When `needle` is non-empty: fetches up to `searchMaxFiles` recent rows,
    ///   then keeps those whose metadata or rollout content matches the needle,
    ///   paginated by `offset`/`limit`.
    ///
    /// - Parameter errorBag: Accumulates open/prepare failures so the caller can
    ///   surface why a search came back short.
    public func loadRecords(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag
    ) async -> [CodexThreadRecord]? {
        guard fileManager.fileExists(atPath: dbPath) else { return nil }

        let snapshot: OpenCodeDatabaseSnapshot
        do {
            guard let madeSnapshot = try OpenCodeDatabaseSnapshot.make(
                prefix: "cmux-codex-search",
                sourcePath: dbPath,
                databaseFilename: "state.db",
                fileManager: fileManager
            ) else {
                return nil
            }
            snapshot = madeSnapshot
        } catch {
            return nil
        }
        defer { snapshot.remove() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            errorBag.add("Codex: cannot open state_5.sqlite (\(db?.sqliteErrorMessage ?? "unknown error"))")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var sql = """
            SELECT id, rollout_path, cwd, title, model, git_branch,
                   approval_mode, sandbox_policy, reasoning_effort,
                   first_user_message, updated_at_ms
            FROM threads
            WHERE archived = 0
            """
        var conditions: [String] = []
        if cwdFilter != nil {
            conditions.append("cwd = ?1")
        }
        if !conditions.isEmpty {
            sql += " AND " + conditions.joined(separator: " AND ")
        }
        if needle.isEmpty {
            sql += " ORDER BY updated_at_ms DESC LIMIT \(limit) OFFSET \(offset)"
        } else {
            sql += " ORDER BY updated_at_ms DESC LIMIT \(searchMaxFiles)"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            errorBag.add("Codex: schema unsupported — \(db.sqliteErrorMessage ?? "prepare failed"). Falling back to file scan.")
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        if let cwdFilter {
            sqlite3_bind_text(stmt, 1, cwdFilter, -1, SQLITE_TRANSIENT_FN)
        }

        var records: [CodexThreadRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(CodexThreadRecord(
                sessionId: stmt.sqliteColumnText(0) ?? "",
                rolloutPath: stmt.sqliteColumnText(1) ?? "",
                cwd: stmt.sqliteColumnText(2),
                titleField: stmt.sqliteColumnText(3) ?? "",
                model: stmt.sqliteColumnText(4),
                gitBranch: stmt.sqliteColumnText(5),
                approvalMode: stmt.sqliteColumnText(6),
                sandboxJSON: stmt.sqliteColumnText(7),
                reasoningEffort: stmt.sqliteColumnText(8),
                firstUserMessage: stmt.sqliteColumnText(9) ?? "",
                updatedMs: sqlite3_column_int64(stmt, 10)
            ))
        }
        guard !needle.isEmpty else {
            return records
        }

        guard limit > 0 else { return [] }
        let normalizedSessionsRoot = (sessionsRoot as NSString).standardizingPath
        let rgMatchedPaths = await rolloutPathsMatchingNeedle(needle, sessionsRoot: normalizedSessionsRoot)
        var matchedCount = 0
        var matched: [CodexThreadRecord] = []
        matched.reserveCapacity(min(limit, records.count))
        for record in records {
            if Task.isCancelled { break }
            let matches = record.matchesMetadata(needle: needle)
                || recordMatchesRolloutContent(
                    record,
                    needle: needle,
                    rgMatchedPaths: rgMatchedPaths,
                    normalizedSessionsRoot: normalizedSessionsRoot
                )
            guard matches else { continue }
            if matchedCount >= offset {
                matched.append(record)
                if matched.count >= limit { break }
            }
            matchedCount += 1
        }
        return matched
    }

    private func rolloutPathsMatchingNeedle(
        _ needle: String,
        sessionsRoot: String
    ) async -> Set<String>? {
        guard let matches = await ripgrepScanner.matchingPaths(
            needle: needle,
            root: sessionsRoot,
            fileGlob: "*.jsonl"
        ) else {
            return nil
        }
        return Set(matches.map { ($0.path as NSString).standardizingPath })
    }

    private func recordMatchesRolloutContent(
        _ record: CodexThreadRecord,
        needle: String,
        rgMatchedPaths: Set<String>?,
        normalizedSessionsRoot: String
    ) -> Bool {
        guard let path = record.normalizedRolloutPath else { return false }
        let isUnderDefaultRoot = path == normalizedSessionsRoot
            || path.hasPrefix(normalizedSessionsRoot + "/")
        if let rgMatchedPaths, isUnderDefaultRoot {
            return rgMatchedPaths.contains(path)
        }
        return Self.fileContainsNeedle(url: URL(fileURLWithPath: path), needle: needle)
    }

    /// Returns whether the file at `url` contains `needle` (case-insensitive,
    /// literal). Used by the rollout content-match fallback when ripgrep is
    /// unavailable or the rollout sits outside the default sessions root.
    static func fileContainsNeedle(url: URL, needle: String) -> Bool {
        guard !needle.isEmpty,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.range(of: needle, options: [.caseInsensitive, .literal]) != nil
    }
}

extension CodexThreadRecord {
    /// Returns whether any indexed metadata field contains `needle`
    /// (case-insensitive, literal): session id, rollout path, cwd, title, first
    /// user message, git branch, model, approval mode, or reasoning effort.
    func matchesMetadata(needle: String) -> Bool {
        func fieldMatches(_ field: String?) -> Bool {
            guard let field else { return false }
            return field.range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }

        if fieldMatches(sessionId) { return true }
        if fieldMatches(rolloutPath) { return true }
        if fieldMatches(cwd) { return true }
        if fieldMatches(titleField) { return true }
        if fieldMatches(firstUserMessage) { return true }
        if fieldMatches(gitBranch) { return true }
        if fieldMatches(model) { return true }
        if fieldMatches(approvalMode) { return true }
        if fieldMatches(reasoningEffort) { return true }
        return false
    }
}
