public import Foundation

/// Reads Firefox's `places.sqlite`: bookmarks (`moz_bookmarks` joined to
/// `moz_places`, folder titles from the parent chain) and history
/// (`moz_places` with visits), newest first.
public struct FirefoxPlacesReader {
    /// Creates a reader for this browser format.
    public init() {}

    let rootGUID = "root________"
    let tagsGUID = "tags________"
    /// Built-in folders store short internal titles ("toolbar", "menu").
    let rootNames = [
        "toolbar_____": "Bookmarks Toolbar",
        "menu________": "Bookmarks Menu",
        "unfiled_____": "Other Bookmarks",
        "mobile______": "Mobile Bookmarks",
    ]

    public func readBookmarks(_ file: URL) throws -> [ImportedBookmark] {
        let database = try SQLiteSnapshot(copying: file)
        // Folders (type 2) by id: title and parent, to build each path.
        var folders: [Int64: (title: String, parent: Int64, guid: String)] = [:]
        try database.query("SELECT id, title, parent, guid FROM moz_bookmarks WHERE type = 2") { row in
            folders[row.int64(0)] = (row.string(1) ?? "", row.int64(2), row.string(3) ?? "")
            return true
        }
        var bookmarks: [ImportedBookmark] = []
        let sql = """
            SELECT p.url, b.title, b.parent, b.dateAdded FROM moz_bookmarks b
            JOIN moz_places p ON p.id = b.fk WHERE b.type = 1 ORDER BY b.parent, b.position
            """
        try database.query(sql) { row in
            guard let text = row.string(0), let url = ImportableURL.parse(text) else { return true }
            var path: [String] = []
            var parent = row.int64(2)
            var depth = 0
            // The root folder (guid root________) ends the chain; entries under
            // the tags root are tag assignments, not bookmarks.
            while let folder = folders[parent], folder.guid != rootGUID, depth < 64 {
                if folder.guid == tagsGUID { return true }
                path.insert(rootNames[folder.guid] ?? folder.title, at: 0)
                parent = folder.parent
                depth += 1
            }
            let title = row.string(1).flatMap { $0.isEmpty ? nil : $0 } ?? text
            bookmarks.append(ImportedBookmark(title: title, url: url, folderPath: path, dateAdded: BrowserTime().mozilla(row.int64(3))))
            return true
        }
        return bookmarks
    }

    public func readHistory(_ file: URL, limit: Int) throws -> [ImportedHistoryEntry] {
        let database = try SQLiteSnapshot(copying: file)
        var entries: [ImportedHistoryEntry] = []
        let sql = """
            SELECT url, title, visit_count, last_visit_date FROM moz_places
            WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL AND \(ImportableURL.sqlFilter("url"))
            ORDER BY last_visit_date DESC LIMIT \(max(0, limit))
            """
        try database.query(sql) { row in
            guard let text = row.string(0), let url = ImportableURL.parse(text),
                  let date = BrowserTime().mozilla(row.int64(3)) else { return true }
            let title = row.string(1).flatMap { $0.isEmpty ? nil : $0 }
            entries.append(ImportedHistoryEntry(url: url, title: title, visitCount: Int(row.int64(2)), lastVisit: date))
            return true
        }
        return entries
    }
}
