import Darwin
import Foundation
import SQLite3

struct CMUXAgentTurnDiffBaselineDatabaseUpdate {
    var removedRecords: [CMUXAgentTurnDiffBaselineRecord]
}

final class CMUXAgentTurnDiffBaselineDatabase {
    private static let schemaVersion = 1
    private static let retentionSeconds: TimeInterval = 60 * 60 * 24 * 7
    private static let recordLimit = 200
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let path: String
    private let legacyJSONPath: String
    private var database: OpaquePointer?

    init(path: String, legacyJSONPath: String) throws {
        self.path = path
        self.legacyJSONPath = legacyJSONPath

        let databaseURL = URL(fileURLWithPath: path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: databaseURL.deletingLastPathComponent().path
        )

        var openedDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let openedDatabase else {
            sqlite3_close(openedDatabase)
            throw Self.databaseError()
        }
        database = openedDatabase
        sqlite3_extended_result_codes(openedDatabase, 1)
        _ = sqlite3_busy_timeout(openedDatabase, 250)

        do {
            try configureSchema()
            try migrateLegacyJSONIfNeeded()
            try setPrivateFilePermissions()
        } catch {
            sqlite3_close(openedDatabase)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func latestRecord(
        repoRoot: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String?
    ) throws -> CMUXAgentTurnDiffBaselineRecord? {
        var sql = """
            SELECT workspace_id, surface_id, session_id, turn_id, agent, repo_root,
                   base_commit, untracked_paths, untracked_path_hashes, snapshot_id, captured_at
            FROM baselines
            WHERE repo_root = ?1 AND workspace_id = ?2 AND surface_id = ?3
            """
        if sessionId != nil {
            sql += " AND session_id = ?4"
        }
        sql += " ORDER BY captured_at DESC LIMIT 1"

        return try withStatement(sql) { statement in
            try bind(canonicalRepoRoot(repoRoot), at: 1, in: statement)
            try bind(canonicalScopeIdentifier(workspaceId), at: 2, in: statement)
            try bind(canonicalScopeIdentifier(surfaceId), at: 3, in: statement)
            if let sessionId {
                try bind(sessionId, at: 4, in: statement)
            }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return nil
            }
            guard result == SQLITE_ROW else {
                throw Self.databaseError()
            }
            return try record(from: statement, includeUntrackedPaths: true)
        }
    }

    func repoRoots(
        workspaceId: String,
        surfaceId: String,
        sessionId: String?
    ) throws -> [String] {
        var sql = """
            SELECT repo_root, MAX(captured_at) AS newest
            FROM baselines
            WHERE workspace_id = ?1 AND surface_id = ?2
            """
        if sessionId != nil {
            sql += " AND session_id = ?3"
        }
        sql += " GROUP BY repo_root ORDER BY newest DESC"

        return try withStatement(sql) { statement in
            try bind(canonicalScopeIdentifier(workspaceId), at: 1, in: statement)
            try bind(canonicalScopeIdentifier(surfaceId), at: 2, in: statement)
            if let sessionId {
                try bind(sessionId, at: 3, in: statement)
            }
            var roots: [String] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return roots
                }
                guard result == SQLITE_ROW else {
                    throw Self.databaseError()
                }
                if let root = text(from: statement, at: 0) {
                    roots.append(root)
                }
            }
        }
    }

    func update(
        with rawRecord: CMUXAgentTurnDiffBaselineRecord,
        preserveExistingTurnBaseline: Bool,
        publishSnapshot: () throws -> Void
    ) throws -> CMUXAgentTurnDiffBaselineDatabaseUpdate {
        var record = rawRecord
        record.repoRoot = canonicalRepoRoot(record.repoRoot)
        record.workspaceId = canonicalScopeIdentifier(record.workspaceId)
        record.surfaceId = canonicalScopeIdentifier(record.surfaceId)

        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer {
            if !committed {
                try? execute("ROLLBACK")
            }
        }

        var removedRecords: [CMUXAgentTurnDiffBaselineRecord] = []
        let existing = try recordForUniqueTurn(record)
        let shouldStore = !(
            preserveExistingTurnBaseline && record.turnId != nil && existing != nil
        )
        if shouldStore {
            try publishSnapshot()
            if let existing {
                removedRecords.append(existing)
            }
            try upsert(record)
        }

        let cutoff = Date().timeIntervalSince1970 - Self.retentionSeconds
        let expired = try recordsForPruning(cutoff: cutoff)
        removedRecords.append(contentsOf: expired)
        try executePruning(cutoff: cutoff)
        try execute("COMMIT")
        committed = true
        return CMUXAgentTurnDiffBaselineDatabaseUpdate(
            removedRecords: deduplicatedRecords(removedRecords)
        )
    }

    func retainedSnapshotIds() throws -> Set<String> {
        try withStatement("SELECT snapshot_id FROM baselines WHERE snapshot_id IS NOT NULL") { statement in
            var snapshotIds: Set<String> = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return snapshotIds
                }
                guard result == SQLITE_ROW else {
                    throw Self.databaseError()
                }
                if let snapshotId = text(from: statement, at: 0) {
                    snapshotIds.insert(snapshotId)
                }
            }
        }
    }

    func containsBaseCommit(repoRoot: String, baseCommit: String) throws -> Bool {
        try contains(
            sql: "SELECT 1 FROM baselines WHERE repo_root = ?1 AND base_commit = ?2 LIMIT 1",
            values: [canonicalRepoRoot(repoRoot), baseCommit]
        )
    }

    func retainedUntrackedHashes(repoRoot: String) throws -> Set<String> {
        try withStatement(
            "SELECT untracked_path_hashes FROM baselines WHERE repo_root = ?1 AND untracked_path_hashes IS NOT NULL"
        ) { statement in
            try bind(canonicalRepoRoot(repoRoot), at: 1, in: statement)
            var hashes: Set<String> = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return hashes
                }
                guard result == SQLITE_ROW else {
                    throw Self.databaseError()
                }
                if let data = data(from: statement, at: 0) {
                    let decoded = try JSONDecoder().decode([String: String].self, from: data)
                    hashes.formUnion(decoded.values)
                }
            }
        }
    }

    private func configureSchema() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS baselines (
                id INTEGER PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                surface_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                turn_id TEXT,
                turn_key TEXT NOT NULL,
                agent TEXT NOT NULL,
                repo_root TEXT NOT NULL,
                base_commit TEXT NOT NULL,
                untracked_paths BLOB,
                untracked_path_hashes BLOB,
                snapshot_id TEXT,
                captured_at REAL NOT NULL,
                UNIQUE(repo_root, workspace_id, surface_id, session_id, turn_key)
            )
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS baselines_latest_scope_idx
            ON baselines(repo_root, workspace_id, surface_id, session_id, captured_at DESC)
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS baselines_repo_picker_idx
            ON baselines(workspace_id, surface_id, session_id, captured_at DESC)
            """)
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    private func migrateLegacyJSONIfNeeded() throws {
        let legacyExists = FileManager.default.fileExists(atPath: legacyJSONPath)
        if try metadataValue(for: "legacy_json_imported") == "1", !legacyExists {
            return
        }

        let lockPath = legacyJSONPath + ".lock"
        if legacyExists || FileManager.default.fileExists(atPath: lockPath) {
            try withLegacyJSONLock {
                try migrateLegacyJSONWhileLocked()
            }
        } else {
            try migrateLegacyStore(CMUXAgentTurnDiffBaselineStore())
        }
    }

    private func migrateLegacyJSONWhileLocked() throws {
        guard FileManager.default.fileExists(atPath: legacyJSONPath) else {
            if try metadataValue(for: "legacy_json_imported") != "1" {
                try migrateLegacyStore(CMUXAgentTurnDiffBaselineStore())
            }
            return
        }
        let legacyURL = URL(fileURLWithPath: legacyJSONPath, isDirectory: false)
        let data = try Data(contentsOf: legacyURL)
        let legacyStore = try JSONDecoder().decode(CMUXAgentTurnDiffBaselineStore.self, from: data)
        try migrateLegacyStore(legacyStore)
        try? FileManager.default.removeItem(atPath: legacyJSONPath)
    }

    private func migrateLegacyStore(_ legacyStore: CMUXAgentTurnDiffBaselineStore) throws {
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer {
            if !committed {
                try? execute("ROLLBACK")
            }
        }
        if try metadataValue(for: "legacy_json_imported") != "1" || !legacyStore.records.isEmpty {
            for record in legacyStore.records.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                try upsert(record)
            }
            let cutoff = Date().timeIntervalSince1970 - Self.retentionSeconds
            try executePruning(cutoff: cutoff)
            try setMetadataValue("1", for: "legacy_json_imported")
        }
        try execute("COMMIT")
        committed = true
    }

    private func withLegacyJSONLock<T>(_ body: () throws -> T) throws -> T {
        let lockPath = legacyJSONPath + ".lock"
        let descriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Self.databaseError()
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw Self.databaseError()
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw Self.databaseError()
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func recordForUniqueTurn(
        _ record: CMUXAgentTurnDiffBaselineRecord
    ) throws -> CMUXAgentTurnDiffBaselineRecord? {
        let sql = """
            SELECT workspace_id, surface_id, session_id, turn_id, agent, repo_root,
                   base_commit, untracked_paths, untracked_path_hashes, snapshot_id, captured_at
            FROM baselines
            WHERE repo_root = ?1 AND workspace_id = ?2 AND surface_id = ?3
              AND session_id = ?4 AND turn_key = ?5
            LIMIT 1
            """
        return try withStatement(sql) { statement in
            try bind(record.repoRoot, at: 1, in: statement)
            try bind(record.workspaceId, at: 2, in: statement)
            try bind(record.surfaceId, at: 3, in: statement)
            try bind(record.sessionId, at: 4, in: statement)
            try bind(turnKey(record.turnId), at: 5, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return nil
            }
            guard result == SQLITE_ROW else {
                throw Self.databaseError()
            }
            return try self.record(from: statement, includeUntrackedPaths: false)
        }
    }

    private func upsert(_ rawRecord: CMUXAgentTurnDiffBaselineRecord) throws {
        var record = rawRecord
        record.repoRoot = canonicalRepoRoot(record.repoRoot)
        record.workspaceId = canonicalScopeIdentifier(record.workspaceId)
        record.surfaceId = canonicalScopeIdentifier(record.surfaceId)
        let sql = """
            INSERT INTO baselines (
                workspace_id, surface_id, session_id, turn_id, turn_key, agent, repo_root,
                base_commit, untracked_paths, untracked_path_hashes, snapshot_id, captured_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(repo_root, workspace_id, surface_id, session_id, turn_key) DO UPDATE SET
                turn_id = excluded.turn_id,
                agent = excluded.agent,
                base_commit = excluded.base_commit,
                untracked_paths = excluded.untracked_paths,
                untracked_path_hashes = excluded.untracked_path_hashes,
                snapshot_id = excluded.snapshot_id,
                captured_at = excluded.captured_at
            """
        try withStatement(sql) { statement in
            try bind(record.workspaceId, at: 1, in: statement)
            try bind(record.surfaceId, at: 2, in: statement)
            try bind(record.sessionId, at: 3, in: statement)
            try bindOptional(record.turnId, at: 4, in: statement)
            try bind(turnKey(record.turnId), at: 5, in: statement)
            try bind(record.agent, at: 6, in: statement)
            try bind(record.repoRoot, at: 7, in: statement)
            try bind(record.baseCommit, at: 8, in: statement)
            try bindOptional(encodedPaths(record.untrackedPaths), at: 9, in: statement)
            try bindOptional(encodedHashes(record.untrackedPathHashes), at: 10, in: statement)
            try bindOptional(record.untrackedSnapshotId, at: 11, in: statement)
            guard sqlite3_bind_double(statement, 12, record.capturedAt) == SQLITE_OK else {
                throw Self.databaseError()
            }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw Self.databaseError()
            }
        }
    }

    private func recordsForPruning(cutoff: TimeInterval) throws -> [CMUXAgentTurnDiffBaselineRecord] {
        let sql = """
            SELECT workspace_id, surface_id, session_id, turn_id, agent, repo_root,
                   base_commit, untracked_paths, untracked_path_hashes, snapshot_id, captured_at
            FROM baselines
            WHERE captured_at < ?1 OR id NOT IN (
                SELECT id FROM baselines ORDER BY captured_at DESC, id DESC LIMIT \(Self.recordLimit)
            )
            """
        return try withStatement(sql) { statement in
            guard sqlite3_bind_double(statement, 1, cutoff) == SQLITE_OK else {
                throw Self.databaseError()
            }
            var records: [CMUXAgentTurnDiffBaselineRecord] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    return records
                }
                guard result == SQLITE_ROW else {
                    throw Self.databaseError()
                }
                records.append(try record(from: statement, includeUntrackedPaths: false))
            }
        }
    }

    private func executePruning(cutoff: TimeInterval) throws {
        let sql = """
            DELETE FROM baselines
            WHERE captured_at < ?1 OR id NOT IN (
                SELECT id FROM baselines ORDER BY captured_at DESC, id DESC LIMIT \(Self.recordLimit)
            )
            """
        try withStatement(sql) { statement in
            guard sqlite3_bind_double(statement, 1, cutoff) == SQLITE_OK else {
                throw Self.databaseError()
            }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw Self.databaseError()
            }
        }
    }

    private func record(
        from statement: OpaquePointer,
        includeUntrackedPaths: Bool
    ) throws -> CMUXAgentTurnDiffBaselineRecord {
        guard let workspaceId = text(from: statement, at: 0),
              let surfaceId = text(from: statement, at: 1),
              let sessionId = text(from: statement, at: 2),
              let agent = text(from: statement, at: 4),
              let repoRoot = text(from: statement, at: 5),
              let baseCommit = text(from: statement, at: 6) else {
            throw Self.databaseError()
        }
        let paths = includeUntrackedPaths ? decodedPaths(data(from: statement, at: 7)) : nil
        let hashes = try decodedHashes(data(from: statement, at: 8))
        return CMUXAgentTurnDiffBaselineRecord(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: sessionId,
            turnId: text(from: statement, at: 3),
            agent: agent,
            repoRoot: repoRoot,
            baseCommit: baseCommit,
            untrackedPaths: paths,
            untrackedPathHashes: hashes,
            untrackedSnapshotId: text(from: statement, at: 9),
            capturedAt: sqlite3_column_double(statement, 10)
        )
    }

    private func deduplicatedRecords(
        _ records: [CMUXAgentTurnDiffBaselineRecord]
    ) -> [CMUXAgentTurnDiffBaselineRecord] {
        var seen: Set<String> = []
        return records.filter { record in
            let key = [
                record.repoRoot,
                record.workspaceId,
                record.surfaceId,
                record.sessionId,
                turnKey(record.turnId),
                String(record.capturedAt)
            ].joined(separator: "\0")
            return seen.insert(key).inserted
        }
    }

    private func encodedPaths(_ paths: [String]?) -> Data? {
        guard let paths, !paths.isEmpty else { return nil }
        return paths.joined(separator: "\0").data(using: .utf8)
    }

    private func decodedPaths(_ data: Data?) -> [String]? {
        guard let data, !data.isEmpty, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }

    private func encodedHashes(_ hashes: [String: String]?) throws -> Data? {
        guard let hashes, !hashes.isEmpty else { return nil }
        return try JSONEncoder().encode(hashes)
    }

    private func decodedHashes(_ data: Data?) throws -> [String: String]? {
        guard let data, !data.isEmpty else { return nil }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func turnKey(_ turnId: String?) -> String {
        turnId ?? ""
    }

    private func canonicalScopeIdentifier(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    private func canonicalRepoRoot(_ value: String) -> String {
        URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            .standardizedFileURL.path
    }

    private func metadataValue(for key: String) throws -> String? {
        try withStatement("SELECT value FROM metadata WHERE key = ?1") { statement in
            try bind(key, at: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return nil
            }
            guard result == SQLITE_ROW else {
                throw Self.databaseError()
            }
            return text(from: statement, at: 0)
        }
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        try withStatement(
            "INSERT INTO metadata(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        ) { statement in
            try bind(key, at: 1, in: statement)
            try bind(value, at: 2, in: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw Self.databaseError()
            }
        }
    }

    private func contains(sql: String, values: [String]) throws -> Bool {
        try withStatement(sql) { statement in
            for (offset, value) in values.enumerated() {
                try bind(value, at: Int32(offset + 1), in: statement)
            }
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                return true
            }
            guard result == SQLITE_DONE else {
                throw Self.databaseError()
            }
            return false
        }
    }

    private func withStatement<T>(
        _ sql: String,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let database else {
            throw Self.databaseError()
        }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw Self.databaseError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw Self.databaseError()
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            sqlite3_free(errorMessage)
            throw Self.databaseError()
        }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
        guard result == SQLITE_OK else {
            throw Self.databaseError()
        }
    }

    private func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            let result = sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else {
                throw Self.databaseError()
            }
            return
        }
        try bind(value, at: index, in: statement)
    }

    private func bindOptional(_ value: Data?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            let result = sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else {
                throw Self.databaseError()
            }
            return
        }
        let result = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transientDestructor)
        }
        guard result == SQLITE_OK else {
            throw Self.databaseError()
        }
    }

    private func text(from statement: OpaquePointer, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func data(from statement: OpaquePointer, at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private func setPrivateFilePermissions() throws {
        for candidate in [path, path + "-wal", path + "-shm"]
            where FileManager.default.fileExists(atPath: candidate) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate)
        }
    }

    private static func databaseError() -> CLIError {
        CLIError(message: CMUXDiffViewerLocalization.string(
            "diffViewer.lastTurnHistoryUnavailable",
            defaultValue: "Unable to access last-turn history."
        ))
    }
}
