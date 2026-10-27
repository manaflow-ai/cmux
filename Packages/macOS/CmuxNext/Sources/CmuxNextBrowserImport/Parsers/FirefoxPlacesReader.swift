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

    /// Bookmarks with their folder path; an address that is missing or not importable is counted, a tag
    /// assignment (an entry under the tags root) is not a bookmark and is left out.
    public func readBookmarks(_ file: URL) throws -> ImportRead<ImportedBookmark> {
        let database = try SQLiteSnapshot(copying: file)
        // Folders (type 2) by id: title and parent, to build each path.
        var folders: [Int64: (title: String, parent: Int64, guid: String)] = [:]
        try database.query("SELECT id, title, parent, guid FROM moz_bookmarks WHERE type = 2") { row in
            folders[row.int64(0)] = (row.string(1) ?? "", row.int64(2), row.string(3) ?? "")
            return true
        }
        var read = ImportRead<ImportedBookmark>()
        let sql = """
            SELECT p.url, b.title, b.parent, b.dateAdded FROM moz_bookmarks b
            LEFT JOIN moz_places p ON p.id = b.fk WHERE b.type = 1 ORDER BY b.parent, b.position
            """
        try database.query(sql) { row in
            var path: [String] = []
            var parent = row.int64(2)
            var depth = 0
            // The root folder (guid root________) ends the chain; entries under
            // the tags root are tag assignments, not bookmarks.
            while let folder = folders[parent], folder.guid != rootGUID, depth < ImportSkipCounts.maximumDepth {
                if folder.guid == tagsGUID { return true }
                path.insert(rootNames[folder.guid] ?? folder.title, at: 0)
                parent = folder.parent
                depth += 1
            }
            guard let text = row.string(0), let url = ImportableURL.parse(text) else {
                read.skipped.notImportable += 1
                return true
            }
            let title = row.string(1).flatMap { $0.isEmpty ? nil : $0 } ?? text
            read.items.append(ImportedBookmark(title: title, url: url, folderPath: path, dateAdded: BrowserTime().mozilla(row.int64(3))))
            return true
        }
        return read
    }

    public func readHistory(_ file: URL, limit: Int) throws -> ImportRead<ImportedHistoryEntry> {
        let database = try SQLiteSnapshot(copying: file)
        // A visited page with no last visit date is counted with the corrupt times.
        let pages = "FROM moz_places WHERE hidden = 0 AND visit_count > 0"
        let kept = BrowserTime.sqlKept("last_visit_date", last: BrowserTime.lastMozilla)
        let skipped = try database.skippedPages(url: "url", kept: kept, source: pages)
        var read = ImportRead<ImportedHistoryEntry>(skipped: skipped)
        let sql = """
            SELECT url, title, visit_count, last_visit_date \(pages) AND \(ImportableURL.sqlFilter("url")) AND \(kept)
            ORDER BY last_visit_date DESC LIMIT \(max(0, limit))
            """
        try database.query(sql) { row in
            guard let text = row.string(0), let url = ImportableURL.parse(text) else {
                read.skipped.notImportable += 1
                return true
            }
            guard let date = BrowserTime().mozilla(row.int64(3)) else {
                read.skipped.badTime += 1
                return true
            }
            let title = row.string(1).flatMap { $0.isEmpty ? nil : $0 }
            read.items.append(ImportedHistoryEntry(url: url, title: title, visitCount: row.int(2), lastVisit: date))
            return true
        }
        return read
    }
}
