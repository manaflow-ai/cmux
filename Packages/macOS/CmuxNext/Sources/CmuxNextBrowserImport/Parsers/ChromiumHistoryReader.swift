public import Foundation

/// Reads a Chromium `History` database (`urls` table: url, title,
/// visit_count, typed_count, last_visit_time), newest first. Pages with an
/// address that is not importable or a corrupt time are counted, not read.
public struct ChromiumHistoryReader {
    /// Creates a reader for this browser format.
    public init() {}

    public func read(_ file: URL, limit: Int) throws -> ImportRead<ImportedHistoryEntry> {
        let database = try SQLiteSnapshot(copying: file)
        let pages = "FROM urls WHERE hidden = 0 AND visit_count > 0"
        let kept = BrowserTime.sqlKept("last_visit_time", last: BrowserTime.lastChromium)
        let skipped = try database.skippedPages(url: "url", kept: kept, source: pages)
        var read = ImportRead<ImportedHistoryEntry>(skipped: skipped)
        let sql = """
            SELECT url, title, visit_count, last_visit_time \(pages) AND \(ImportableURL.sqlFilter("url")) AND \(kept)
            ORDER BY last_visit_time DESC LIMIT \(max(0, limit))
            """
        try database.query(sql) { row in
            guard let text = row.string(0), let url = ImportableURL.parse(text) else {
                read.skipped.notImportable += 1
                return true
            }
            guard let date = BrowserTime().chromium(row.int64(3)) else {
                read.skipped.badTime += 1
                return true
            }
            let title = row.string(1).flatMap { $0.isEmpty ? nil : $0 }
            read.items.append(ImportedHistoryEntry(url: url, title: title, visitCount: Int(row.int64(2)), lastVisit: date))
            return true
        }
        return read
    }
}
