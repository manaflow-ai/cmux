public import Foundation

/// Parses a Chromium `Bookmarks` file (JSON: `roots.bookmark_bar`,
/// `roots.other`, `roots.synced`, each a folder of `url` and `folder` nodes).
public struct ChromiumBookmarksParser {
    /// Creates a parser for Chromium bookmarks.
    public init() {}

    public enum Failure: Error { case notBookmarks }

    public func parse(_ data: Data) throws -> ImportRead<ImportedBookmark> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw Failure.notBookmarks }
        var read = ImportRead<ImportedBookmark>()
        for key in ["bookmark_bar", "other", "synced"] {
            guard let folder = roots[key] as? [String: Any] else { continue }
            let name = (folder["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            walk(folder, path: [name], depth: 0, into: &read)
        }
        return read
    }

    /// JSON holds a tree (no shared nodes), so each folder is read once; past
    /// ``ImportSkipCounts/maximumDepth`` a folder is counted, not opened.
    private func walk(_ node: [String: Any], path: [String], depth: Int, into read: inout ImportRead<ImportedBookmark>) {
        for element in node["children"] as? [Any] ?? [] {
            guard let child = element as? [String: Any] else {
                read.skipped.unsupported += 1
                continue
            }
            let name = child["name"] as? String ?? ""
            switch child["type"] as? String {
            case "url":
                guard let text = child["url"] as? String, let url = ImportableURL.parse(text) else {
                    read.skipped.notImportable += 1
                    continue
                }
                let added = (child["date_added"] as? String).flatMap { Int64($0) }.flatMap { BrowserTime().chromium($0) }
                read.items.append(ImportedBookmark(title: name.isEmpty ? text : name, url: url, folderPath: path, dateAdded: added))
            case "folder":
                guard depth + 1 < ImportSkipCounts.maximumDepth else {
                    read.skipped.tooDeep += 1
                    continue
                }
                walk(child, path: path + [name], depth: depth + 1, into: &read)
            default:
                read.skipped.unsupported += 1
            }
        }
    }
}
