import Foundation
import SQLite3

extension CMUXCLI {
    final class MemoryTelemetryDatabase {
        private let url: URL
        private var db: OpaquePointer?

        var path: String {
            url.path
        }

        init(url: URL) {
            self.url = url
        }

        deinit {
            close()
        }

        func open() throws {
            guard db == nil else { return }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            let result = sqlite3_open_v2(url.path, &db, flags, nil)
            guard result == SQLITE_OK, db != nil else {
                let message = sqliteMessage() ?? "SQLite open failed with code \(result)"
                close()
                throw CLIError(message: message)
            }
            _ = sqlite3_busy_timeout(db, 1000)
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA foreign_keys=ON")
            try migrate()
        }

        func close() {
            if let db {
                sqlite3_close(db)
            }
            db = nil
        }

        func insert(samples: [MemoryWorkspaceSample], retention: TimeInterval) throws {
            try open()
            try exec("BEGIN IMMEDIATE")
            do {
                for sample in samples {
                    try insert(sample: sample)
                }
                try prune(retention: retention)
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }

        func topRows(since: TimeInterval, limit: Int, retention: TimeInterval, sort: MemoryTopSort) throws -> [[String: Any]] {
            try open()
            try prune(retention: retention)

            let cutoff = Date().addingTimeInterval(-since).timeIntervalSince1970
            let orderBy: String
            switch sort {
            case .peak:
                orderBy = "MAX(rss_bytes) DESC, AVG(rss_bytes) DESC"
            case .average:
                orderBy = "AVG(rss_bytes) DESC, MAX(rss_bytes) DESC"
            }
            let sql = """
            SELECT
                workspace_id,
                COALESCE(MAX(workspace_ref), ''),
                COALESCE(MAX(workspace_title), ''),
                COUNT(*),
                MAX(rss_bytes),
                AVG(rss_bytes),
                MAX(memory_percent),
                AVG(memory_percent),
                MAX(cpu_percent),
                AVG(cpu_percent),
                MAX(process_count),
                MAX(sampled_at)
            FROM workspace_memory_samples
            WHERE sampled_at >= ?
            GROUP BY workspace_id
            ORDER BY \(orderBy)
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw CLIError(message: sqliteMessage() ?? "SQLite prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(max(1, limit)))

            var rows: [[String: Any]] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                rows.append([
                    "workspace_id": sqliteText(stmt, 0) ?? "",
                    "workspace_ref": sqliteText(stmt, 1) ?? "",
                    "workspace_title": sqliteText(stmt, 2) ?? "",
                    "sample_count": Int(sqlite3_column_int64(stmt, 3)),
                    "peak_rss_bytes": sqlite3_column_int64(stmt, 4),
                    "avg_rss_bytes": sqlite3_column_double(stmt, 5),
                    "peak_memory_percent": sqlite3_column_double(stmt, 6),
                    "avg_memory_percent": sqlite3_column_double(stmt, 7),
                    "peak_cpu_percent": sqlite3_column_double(stmt, 8),
                    "avg_cpu_percent": sqlite3_column_double(stmt, 9),
                    "peak_process_count": Int(sqlite3_column_int64(stmt, 10)),
                    "last_sampled_at": ISO8601DateFormatter().string(
                        from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
                    ),
                    "approximate": true
                ])
                stepResult = sqlite3_step(stmt)
            }
            guard stepResult == SQLITE_DONE else {
                throw CLIError(message: sqliteMessage() ?? "SQLite step failed")
            }
            return rows
        }

        private func migrate() throws {
            try exec("""
            CREATE TABLE IF NOT EXISTS workspace_memory_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sampled_at REAL NOT NULL,
                workspace_id TEXT NOT NULL,
                workspace_ref TEXT,
                workspace_title TEXT,
                window_id TEXT,
                window_ref TEXT,
                rss_bytes INTEGER NOT NULL,
                virtual_bytes INTEGER NOT NULL,
                memory_percent REAL NOT NULL DEFAULT 0,
                cpu_percent REAL NOT NULL,
                process_count INTEGER NOT NULL,
                top_process_names TEXT NOT NULL
            )
            """)
            if try !columnExists("workspace_memory_samples", column: "memory_percent") {
                try exec("ALTER TABLE workspace_memory_samples ADD COLUMN memory_percent REAL NOT NULL DEFAULT 0")
            }
            try exec("CREATE INDEX IF NOT EXISTS idx_workspace_memory_samples_time ON workspace_memory_samples(sampled_at)")
            try exec("CREATE INDEX IF NOT EXISTS idx_workspace_memory_samples_workspace_time ON workspace_memory_samples(workspace_id, sampled_at)")
        }

        private func insert(sample: MemoryWorkspaceSample) throws {
            let sql = """
            INSERT INTO workspace_memory_samples (
                sampled_at, workspace_id, workspace_ref, workspace_title, window_id, window_ref,
                rss_bytes, virtual_bytes, memory_percent, cpu_percent, process_count, top_process_names
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw CLIError(message: sqliteMessage() ?? "SQLite prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            sqlite3_bind_double(stmt, 1, sample.sampledAt.timeIntervalSince1970)
            bindText(stmt, 2, sample.workspaceId, transient: transient)
            bindText(stmt, 3, sample.workspaceRef, transient: transient)
            bindText(stmt, 4, sample.workspaceTitle, transient: transient)
            bindText(stmt, 5, sample.windowId, transient: transient)
            bindText(stmt, 6, sample.windowRef, transient: transient)
            sqlite3_bind_int64(stmt, 7, sample.residentBytes)
            sqlite3_bind_int64(stmt, 8, sample.virtualBytes)
            sqlite3_bind_double(stmt, 9, sample.memoryPercent)
            sqlite3_bind_double(stmt, 10, sample.cpuPercent)
            sqlite3_bind_int64(stmt, 11, Int64(sample.processCount))
            bindText(stmt, 12, Self.jsonArray(sample.topProcessNames), transient: transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CLIError(message: sqliteMessage() ?? "SQLite insert failed")
            }
        }

        private func columnExists(_ table: String, column: String) throws -> Bool {
            var stmt: OpaquePointer?
            let sql = "PRAGMA table_info(\(table))"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw CLIError(message: sqliteMessage() ?? "SQLite prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                if sqliteText(stmt, 1) == column {
                    return true
                }
                stepResult = sqlite3_step(stmt)
            }
            guard stepResult == SQLITE_DONE else {
                throw CLIError(message: sqliteMessage() ?? "SQLite step failed")
            }
            return false
        }

        private func prune(retention: TimeInterval) throws {
            guard retention > 0 else { return }
            let cutoff = Date().addingTimeInterval(-retention).timeIntervalSince1970
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM workspace_memory_samples WHERE sampled_at < ?", -1, &stmt, nil) == SQLITE_OK,
                  let stmt else {
                throw CLIError(message: sqliteMessage() ?? "SQLite prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CLIError(message: sqliteMessage() ?? "SQLite prune failed")
            }
        }

        private func exec(_ sql: String) throws {
            var errorMessage: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? sqliteMessage() ?? "SQLite exec failed"
                if let errorMessage { sqlite3_free(errorMessage) }
                throw CLIError(message: message)
            }
        }

        private func bindText(
            _ stmt: OpaquePointer,
            _ index: Int32,
            _ value: String?,
            transient: sqlite3_destructor_type
        ) {
            guard let value else {
                sqlite3_bind_null(stmt, index)
                return
            }
            sqlite3_bind_text(stmt, index, value, -1, transient)
        }

        private func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
                  let cString = sqlite3_column_text(stmt, index) else {
                return nil
            }
            return String(cString: cString)
        }

        private func sqliteMessage() -> String? {
            guard let db, let cString = sqlite3_errmsg(db) else { return nil }
            return String(cString: cString)
        }

        private static func jsonArray(_ values: [String]) -> String {
            guard JSONSerialization.isValidJSONObject(values),
                  let data = try? JSONSerialization.data(withJSONObject: values, options: []),
                  let text = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return text
        }
    }

}
