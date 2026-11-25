@testable import CmuxNextBrowserImport
import Foundation
import SQLite3

/// Readers for tests with no daemon: the cmux-browser-import crate's tests pin each reader's
/// rules and replies; these stand in for the daemon's `browser_import.read` on the wire.
extension BrowserDataReader {
    /// Every read finds nothing (no bookmarks, no pages, no engine).
    nonisolated static let empty = BrowserDataReader { _ in Data(#"{"ok": null}"#.utf8) }

    /// Every read fails the way an unreadable source does.
    nonisolated static let offline = BrowserDataReader { _ in Data(#"{"error": {"kind": "read", "message": "no daemon in this test"}}"#.utf8) }

    /// Answers `chromium.history` from the `urls` table of the database named, newest first,
    /// in the reply shape the daemon sends (dates in seconds since 2001); any other read fails.
    nonisolated static let historyFixture = BrowserDataReader { request in
        let fields = try JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:]
        guard fields["reader"] as? String == "chromium.history", let path = fields["path"] as? String else {
            return try await offline.transport(request)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT url, title, visit_count, last_visit_time FROM urls ORDER BY last_visit_time DESC",
                                 -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let microseconds = Double(sqlite3_column_int64(statement, 3))
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            rows.append(["url": text(0), "title": text(1),
                         "visitCount": Int(sqlite3_column_int64(statement, 2)),
                         "lastVisit": microseconds / 1_000_000 - 11_644_473_600 - Date.timeIntervalBetween1970AndReferenceDate])
        }
        return try JSONSerialization.data(withJSONObject: ["ok": rows])
    }
}
