public import Foundation

/// Parses Safari's `Bookmarks.plist`: nested `WebBookmarkTypeList` folders
/// and `WebBookmarkTypeLeaf` bookmarks. The Favorites bar, the Bookmarks
/// menu and the Reading List get readable folder names.
public struct SafariBookmarksParser {
    /// Entries read at most: a backstop behind the read-each-folder-once rule; no real
    /// Bookmarks.plist comes near it.
    let maximumNodes: Int

    /// Creates a reader for Safari bookmarks.
    public init() {
        self.init(maximumNodes: 1 << 18)
    }

    init(maximumNodes: Int) {
        self.maximumNodes = maximumNodes
    }

    public enum Failure: Error { case notBookmarks }

    /// One walk's state: what is read, the folder contents opened, and the entries left before
    /// ``maximumNodes``. A binary plist names an object by reference, and the reader hands back one
    /// object per reference (CFBinaryPlist), so a damaged file that lists one folder from many
    /// parents, or one `Children` array from many folders, gives the same `NSArray` each time: it is
    /// read once and every other mention is counted. Real files never share one (CFBinaryPlistWrite
    /// writes each array and dictionary out on its own). The opened arrays are held, not only their
    /// identities: where the reader hands back bridged copies (corelibs Foundation on Linux), a copy freed
    /// after its walk could give its address to the next folder's, which would then read as repeated.
    private struct Walk {
        var read = ImportRead<ImportedBookmark>()
        var opened: [ObjectIdentifier: NSArray] = [:]
        var remaining: Int

        /// Whether `contents` is opened for the first time (and now held).
        mutating func open(_ contents: NSArray) -> Bool {
            opened.updateValue(contents, forKey: ObjectIdentifier(contents)) == nil
        }
    }

    public func parse(_ data: Data) throws -> ImportRead<ImportedBookmark> {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary else {
            throw Failure.notBookmarks
        }
        var state = Walk(remaining: maximumNodes)
        let children = root["Children"] as? NSArray ?? NSArray()
        _ = state.open(children)
        walk(children, path: [], depth: 0, state: &state)
        return state.read
    }

    /// Reads `children` (the plist's own objects, never a bridged copy, so identity holds).
    private func walk(_ children: NSArray, path: [String], depth: Int, state: inout Walk) {
        for element in children {
            guard state.remaining > 0 else {
                state.read.skipped.overLimit += 1
                continue
            }
            state.remaining -= 1
            guard let child = element as? NSDictionary else {
                state.read.skipped.unsupported += 1
                continue
            }
            switch child["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let text = child["URLString"] as? String, let url = ImportableURL.parse(text) else {
                    state.read.skipped.notImportable += 1
                    continue
                }
                let title = ((child["URIDictionary"] as? NSDictionary)?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                state.read.items.append(ImportedBookmark(title: title ?? text, url: url, folderPath: path))
            case "WebBookmarkTypeList":
                guard depth + 1 < ImportSkipCounts.maximumDepth else {
                    state.read.skipped.tooDeep += 1
                    continue
                }
                // An empty folder has nothing to read again (and CF may share one empty array).
                let contents = child["Children"] as? NSArray ?? NSArray()
                guard contents.count == 0 || state.open(contents) else {
                    state.read.skipped.repeatedFolder += 1
                    continue
                }
                walk(contents, path: path + [folderName(child["Title"] as? String ?? "")], depth: depth + 1, state: &state)
            case "WebBookmarkTypeProxy":
                continue  // The History entry, not a bookmark.
            default:
                state.read.skipped.unsupported += 1
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
/// visit times in seconds since 2001), newest first. Pages with an address
/// that is not importable or a corrupt last visit are counted, not read.
public struct SafariHistoryReader {
    /// Creates a reader for Safari bookmarks or history.
    public init() {}

    public func read(_ file: URL, limit: Int) throws -> ImportRead<ImportedHistoryEntry> {
        let database = try SQLiteSnapshot(copying: file)
        let visited = "FROM history_items i JOIN history_visits v ON v.history_item = i.id"
        let kept = BrowserTime.sqlKept("last", last: BrowserTime.lastCocoa)
        // Every item is a page: one with no visit has no time and is counted with the corrupt times.
        let pages = "FROM (SELECT i.url AS url, MAX(v.visit_time) AS last FROM history_items i LEFT JOIN history_visits v ON v.history_item = i.id GROUP BY i.id)"
        let skipped = try database.skippedPages(url: "url", kept: kept, source: pages)
        var read = ImportRead<ImportedHistoryEntry>(skipped: skipped)
        let sql = """
            SELECT i.url, (SELECT v2.title FROM history_visits v2 WHERE v2.history_item = i.id
                           ORDER BY v2.visit_time DESC LIMIT 1),
                   i.visit_count, MAX(v.visit_time) AS last
            \(visited) WHERE \(ImportableURL.sqlFilter("i.url"))
            GROUP BY i.id HAVING \(kept) ORDER BY last DESC LIMIT \(max(0, limit))
            """
        try database.query(sql) { row in
            guard let text = row.string(0), let url = ImportableURL.parse(text) else {
                read.skipped.notImportable += 1
                return true
            }
            guard let date = BrowserTime().cocoa(row.double(3)) else {
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
