public import Foundation

/// Parses Safari's `Bookmarks.plist`: nested `WebBookmarkTypeList` folders
/// and `WebBookmarkTypeLeaf` bookmarks. The Favorites bar, the Bookmarks
/// menu and the Reading List get readable folder names.
public struct SafariBookmarksParser {
    /// Creates a reader for Safari bookmarks or history.
    public init() {}

    public enum Failure: Error { case notBookmarks }

    public func parse(_ data: Data) throws -> [ImportedBookmark] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.notBookmarks
        }
        var result: [ImportedBookmark] = []
        walk(root, path: [], into: &result)
        return result
    }

    private func walk(_ node: [String: Any], path: [String], into result: inout [ImportedBookmark]) {
        for child in node["Children"] as? [[String: Any]] ?? [] {
            switch child["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let text = child["URLString"] as? String, let url = ImportableURL.parse(text) else { continue }
                let title = ((child["URIDictionary"] as? [String: Any])?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                result.append(ImportedBookmark(title: title ?? text, url: url, folderPath: path))
            case "WebBookmarkTypeList":
                walk(child, path: path + [folderName(child["Title"] as? String ?? "")], into: &result)
            default:
                continue  // WebBookmarkTypeProxy: the History entry.
            }
        }
    }

    private func folderName(_ title: String) -> String {
        switch title {
        case "BookmarksBar": "Favorites"
        case "BookmarksMenu": "Bookmarks Menu"
        case "com.apple.ReadingList": "Reading List"
        default: title
        }
    }
}

/// Reads Safari's `History.db` (`history_items` and `history_visits`,
/// visit times in seconds since 2001), newest first.
public struct SafariHistoryReader {
    /// Creates a reader for Safari bookmarks or history.
    public init() {}

    public func read(_ file: URL, limit: Int) throws -> [ImportedHistoryEntry] {
        let database = try SQLiteSnapshot(copying: file)
        var entries: [ImportedHistoryEntry] = []
        let sql = """
            SELECT i.url, (SELECT v2.title FROM history_visits v2 WHERE v2.history_item = i.id
                           ORDER BY v2.visit_time DESC LIMIT 1),
                   i.visit_count, MAX(v.visit_time) AS last
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            WHERE \(ImportableURL.sqlFilter("i.url"))
            GROUP BY i.id ORDER BY last DESC LIMIT \(max(0, limit))
            """
        try database.query(sql) { row in
            guard let text = row.string(0), let url = ImportableURL.parse(text),
                  let date = BrowserTime().cocoa(row.double(3)) else { return true }
            let title = row.string(1).flatMap { $0.isEmpty ? nil : $0 }
            entries.append(ImportedHistoryEntry(url: url, title: title, visitCount: Int(row.int64(2)), lastVisit: date))
            return true
        }
        return entries
    }
}
