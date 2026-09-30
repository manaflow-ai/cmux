public import Foundation

/// Reads a Chromium `History` database (`urls` table: url, title,
/// visit_count, typed_count, last_visit_time), newest first.
public enum ChromiumHistoryReader {
    public static func read(_ file: URL, limit: Int) throws -> [ImportedHistoryEntry] {
        let database = try SQLiteSnapshot(copying: file)
        var entries: [ImportedHistoryEntry] = []
        let sql = """
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE hidden = 0 AND visit_count > 0 AND \(ImportableURL.sqlFilter("url")) ORDER BY last_visit_time DESC LIMIT \(max(0, limit))
            """
        try database.query(sql) { row in
            guard let text = row.string(0), let url = ImportableURL.parse(text),
                  let date = BrowserTime.chromium(row.int64(3)) else { return true }
            let title = row.string(1).flatMap { $0.isEmpty ? nil : $0 }
            entries.append(ImportedHistoryEntry(url: url, title: title, visitCount: Int(row.int64(2)), lastVisit: date))
            return true
        }
        return entries
    }
}
