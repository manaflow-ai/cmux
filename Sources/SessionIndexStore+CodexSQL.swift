import Foundation
import SQLite3

extension SessionIndexStore {
    private struct CodexThreadRecord: Sendable {
        let sessionId: String
        let rolloutPath: String
        let cwd: String?
        let titleField: String
        let model: String?
        let gitBranch: String?
        let approvalMode: String?
        let sandboxJSON: String?
        let reasoningEffort: String?
        let firstUserMessage: String
        let updatedMs: Int64
        let sourceJSON: String?
        let threadSource: String?
        let agentNickname: String?
        let agentRole: String?
        let parentSessionId: String?
        let parentRolloutPath: String?
        let spawnStatus: String?

        var normalizedRolloutPath: String? {
            let trimmed = rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (trimmed as NSString).standardizingPath
        }

        var normalizedParentRolloutPath: String? {
            let trimmed = parentRolloutPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return (trimmed as NSString).standardizingPath
        }
    }

    private struct CodexSubagentSource: Sendable {
        let parentSessionId: String?
        let depth: Int?
        let agentNickname: String?
        let agentRole: String?
        let legacyRole: String?
    }

    /// SQL-backed Codex loader. Returns nil if `state_5.sqlite` doesn't exist
    /// so the caller can fall back to the disk scan.
    nonisolated static func loadCodexEntriesViaSQL(
        needle: String, cwdFilter: String?, offset: Int, limit: Int,
        errorBag: ErrorBag,
        dbPath: String = ("~/.codex/state_5.sqlite" as NSString).expandingTildeInPath,
        sessionsRoot: String = defaultCodexSessionsRoot()
    ) async -> [SessionEntry]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return nil }

        let snapshotDir = fm.temporaryDirectory.appendingPathComponent(
            "cmux-codex-search-\(UUID().uuidString)", isDirectory: true
        )
        do { try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true) } catch { return nil }
        defer { try? fm.removeItem(at: snapshotDir) }
        let snapshotDB = snapshotDir.appendingPathComponent("state.db")
        do { try fm.copyItem(atPath: dbPath, toPath: snapshotDB.path) } catch { return nil }
        for sidecar in ["-wal", "-shm"] {
            let src = dbPath + sidecar
            let dst = snapshotDB.path + sidecar
            if fm.fileExists(atPath: src) { try? fm.copyItem(atPath: src, toPath: dst) }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshotDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            errorBag.add("Codex: cannot open state_5.sqlite (\(sqliteMessage(db) ?? "unknown error"))")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let threadColumns = sqliteColumnNames(in: "threads", db: db)
        let hasSpawnEdges = sqliteTableExists("thread_spawn_edges", db: db)
        let sourceSelect = threadColumns.contains("source") ? "t.source" : "NULL"
        let threadSourceSelect = threadColumns.contains("thread_source") ? "t.thread_source" : "NULL"
        let nicknameSelect = threadColumns.contains("agent_nickname") ? "t.agent_nickname" : "NULL"
        let roleSelect = threadColumns.contains("agent_role") ? "t.agent_role" : "NULL"
        let edgeJoin = hasSpawnEdges
            ? """

            LEFT JOIN thread_spawn_edges e ON e.child_thread_id = t.id
            LEFT JOIN threads p ON p.id = e.parent_thread_id
            """
            : ""
        let parentSelect = hasSpawnEdges ? "e.parent_thread_id" : "NULL"
        let parentRolloutSelect = hasSpawnEdges ? "p.rollout_path" : "NULL"
        let spawnStatusSelect = hasSpawnEdges ? "e.status" : "NULL"

        var sql = """
            SELECT t.id, t.rollout_path, t.cwd, t.title, t.model, t.git_branch,
                   t.approval_mode, t.sandbox_policy, t.reasoning_effort,
                   t.first_user_message, t.updated_at_ms,
                   \(sourceSelect), \(threadSourceSelect), \(nicknameSelect), \(roleSelect),
                   \(parentSelect), \(parentRolloutSelect), \(spawnStatusSelect)
            FROM threads t
            \(edgeJoin)
            WHERE t.archived = 0
            """
        var conditions: [String] = []
        if cwdFilter != nil {
            conditions.append("t.cwd = ?1")
        }
        if !conditions.isEmpty {
            sql += " AND " + conditions.joined(separator: " AND ")
        }
        if needle.isEmpty {
            sql += " ORDER BY t.updated_at_ms DESC LIMIT \(limit) OFFSET \(offset)"
        } else {
            sql += " ORDER BY t.updated_at_ms DESC LIMIT \(searchMaxFiles)"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            errorBag.add("Codex: schema unsupported — \(sqliteMessage(db) ?? "prepare failed"). Falling back to file scan.")
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
                sessionId: sqliteText(stmt, 0) ?? "",
                rolloutPath: sqliteText(stmt, 1) ?? "",
                cwd: sqliteText(stmt, 2),
                titleField: sqliteText(stmt, 3) ?? "",
                model: sqliteText(stmt, 4),
                gitBranch: sqliteText(stmt, 5),
                approvalMode: sqliteText(stmt, 6),
                sandboxJSON: sqliteText(stmt, 7),
                reasoningEffort: sqliteText(stmt, 8),
                firstUserMessage: sqliteText(stmt, 9) ?? "",
                updatedMs: sqlite3_column_int64(stmt, 10),
                sourceJSON: sqliteText(stmt, 11),
                threadSource: sqliteText(stmt, 12),
                agentNickname: sqliteText(stmt, 13),
                agentRole: sqliteText(stmt, 14),
                parentSessionId: sqliteText(stmt, 15),
                parentRolloutPath: sqliteText(stmt, 16),
                spawnStatus: sqliteText(stmt, 17)
            ))
        }
        guard !needle.isEmpty else {
            return records.map(codexEntry(from:))
        }

        guard limit > 0 else { return [] }
        let normalizedSessionsRoot = (sessionsRoot as NSString).standardizingPath
        let rgMatchedPaths = await codexRolloutPathsMatchingNeedle(needle, sessionsRoot: normalizedSessionsRoot)
        var matchedCount = 0
        var entries: [SessionEntry] = []
        entries.reserveCapacity(min(limit, records.count))
        for record in records {
            if Task.isCancelled { break }
            let matches = codexRecordMatchesMetadata(record, needle: needle)
                || codexRecordMatchesRolloutContent(
                    record,
                    needle: needle,
                    rgMatchedPaths: rgMatchedPaths,
                    normalizedSessionsRoot: normalizedSessionsRoot
                )
            guard matches else { continue }
            if matchedCount >= offset {
                entries.append(codexEntry(from: record))
                if entries.count >= limit { break }
            }
            matchedCount += 1
        }
        return entries
    }

    #if DEBUG
    nonisolated static func loadCodexEntriesForTesting(
        stateDBPath: String,
        needle: String,
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100,
        sessionsRoot: String = defaultCodexSessionsRoot()
    ) async -> SearchOutcome {
        let bag = ErrorBag()
        let entries = await loadCodexEntriesViaSQL(
            needle: needle.lowercased(),
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            dbPath: stateDBPath,
            sessionsRoot: sessionsRoot
        ) ?? []
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif

    nonisolated private static func codexEntry(from record: CodexThreadRecord) -> SessionEntry {
        let sandboxMode = record.sandboxJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["type"] as? String }

        let displayTitle: String
        if !record.titleField.isEmpty {
            displayTitle = record.titleField
        } else if let real = realCodexUserMessage(record.firstUserMessage) {
            displayTitle = real
        } else {
            displayTitle = ""
        }

        let fileURL = record.normalizedRolloutPath.map { URL(fileURLWithPath: $0) }
        let subagent = codexSubagentMetadata(from: record)
        return SessionEntry(
            id: "codex:" + (fileURL?.path ?? record.sessionId),
            agent: .codex,
            sessionId: record.sessionId,
            title: displayTitle,
            cwd: record.cwd,
            gitBranch: record.gitBranch?.isEmpty == false ? record.gitBranch : nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: TimeInterval(record.updatedMs) / 1000.0),
            fileURL: fileURL,
            specifics: .codex(
                model: record.model?.isEmpty == false ? record.model : nil,
                approvalPolicy: record.approvalMode?.isEmpty == false ? record.approvalMode : nil,
                sandboxMode: sandboxMode,
                effort: record.reasoningEffort?.isEmpty == false ? record.reasoningEffort : nil
            ),
            subagent: subagent
        )
    }

    nonisolated private static func codexRecordMatchesMetadata(_ record: CodexThreadRecord, needle: String) -> Bool {
        func fieldMatches(_ field: String?) -> Bool {
            guard let field else { return false }
            return field.range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }

        if fieldMatches(record.sessionId) { return true }
        if fieldMatches(record.rolloutPath) { return true }
        if fieldMatches(record.cwd) { return true }
        if fieldMatches(record.titleField) { return true }
        if fieldMatches(record.firstUserMessage) { return true }
        if fieldMatches(record.gitBranch) { return true }
        if fieldMatches(record.model) { return true }
        if fieldMatches(record.approvalMode) { return true }
        if fieldMatches(record.reasoningEffort) { return true }
        if fieldMatches(record.sourceJSON) { return true }
        if fieldMatches(record.threadSource) { return true }
        if fieldMatches(record.agentNickname) { return true }
        if fieldMatches(record.agentRole) { return true }
        if fieldMatches(record.parentSessionId) { return true }
        if fieldMatches(record.parentRolloutPath) { return true }
        if fieldMatches(record.spawnStatus) { return true }
        if codexSubagentMetadata(from: record)?.searchableTerms.contains(where: { fieldMatches($0) }) == true {
            return true
        }
        return false
    }

    nonisolated private static func codexSubagentMetadata(
        from record: CodexThreadRecord
    ) -> SessionSubagentMetadata? {
        let source = codexSubagentSource(record.sourceJSON)
        let parentSessionId = normalizedOptional(record.parentSessionId) ?? source?.parentSessionId
        let nickname = normalizedOptional(record.agentNickname) ?? source?.agentNickname
        let role = normalizedOptional(record.agentRole) ?? source?.agentRole ?? source?.legacyRole
        let isSubagent = parentSessionId != nil
            || normalizedOptional(record.threadSource) == "subagent"
            || source != nil

        guard isSubagent else { return nil }
        return SessionSubagentMetadata(
            provider: .codex,
            parentSessionId: parentSessionId,
            subagentId: record.sessionId,
            depth: source?.depth,
            status: record.spawnStatus,
            name: nickname,
            role: role,
            parentFileURL: record.normalizedParentRolloutPath.map { URL(fileURLWithPath: $0) }
        )
    }

    nonisolated private static func codexSubagentSource(_ sourceJSON: String?) -> CodexSubagentSource? {
        guard let data = sourceJSON?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subagent = object["subagent"] else {
            return nil
        }

        if let role = subagent as? String {
            return CodexSubagentSource(
                parentSessionId: nil,
                depth: nil,
                agentNickname: nil,
                agentRole: nil,
                legacyRole: normalizedOptional(role)
            )
        }

        guard let subagentObject = subagent as? [String: Any] else { return nil }
        if let spawn = subagentObject["thread_spawn"] as? [String: Any] {
            return CodexSubagentSource(
                parentSessionId: normalizedOptional(spawn["parent_thread_id"] as? String),
                depth: spawn["depth"] as? Int,
                agentNickname: normalizedOptional(spawn["agent_nickname"] as? String),
                agentRole: normalizedOptional(spawn["agent_role"] as? String),
                legacyRole: nil
            )
        }

        return CodexSubagentSource(
            parentSessionId: normalizedOptional(subagentObject["parent_thread_id"] as? String),
            depth: subagentObject["depth"] as? Int,
            agentNickname: normalizedOptional(subagentObject["agent_nickname"] as? String),
            agentRole: normalizedOptional(subagentObject["agent_role"] as? String),
            legacyRole: nil
        )
    }

    nonisolated private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated private static func sqliteColumnNames(in table: String, db: OpaquePointer) -> Set<String> {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info('\(escapedTable)')", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqliteText(stmt, 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    nonisolated private static func sqliteTableExists(_ table: String, db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return false
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT_FN)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    nonisolated private static func defaultCodexSessionsRoot() -> String {
        let root = ("~/.codex/sessions" as NSString).expandingTildeInPath
        return (root as NSString).standardizingPath
    }

    nonisolated private static func codexRolloutPathsMatchingNeedle(
        _ needle: String,
        sessionsRoot: String
    ) async -> Set<String>? {
        guard let matches = await ripgrepMatchingPaths(
            needle: needle,
            root: sessionsRoot,
            fileGlob: "*.jsonl"
        ) else {
            return nil
        }
        return Set(matches.map { ($0.path as NSString).standardizingPath })
    }

    nonisolated private static func codexRecordMatchesRolloutContent(
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
        return fileContainsNeedle(url: URL(fileURLWithPath: path), needle: needle)
    }
}
