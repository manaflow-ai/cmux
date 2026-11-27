public import Foundation

/// Parses a Chromium `Bookmarks` file (JSON: `roots.bookmark_bar`,
/// `roots.other`, `roots.synced`, each a folder of `url` and `folder` nodes).
public struct ChromiumBookmarksParser {
    /// Creates a parser for Chromium bookmarks.
    public init() {}

    public enum Failure: Error { case notBookmarks }

    public func parse(_ data: Data) throws -> [ImportedBookmark] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw Failure.notBookmarks }
        var result: [ImportedBookmark] = []
        for key in ["bookmark_bar", "other", "synced"] {
            guard let folder = roots[key] as? [String: Any] else { continue }
            let name = (folder["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            walk(folder, path: [name], into: &result)
        }
        return result
    }

    private func walk(_ node: [String: Any], path: [String], into result: inout [ImportedBookmark]) {
        for child in node["children"] as? [[String: Any]] ?? [] {
            let name = child["name"] as? String ?? ""
            switch child["type"] as? String {
            case "url":
                guard let text = child["url"] as? String, let url = ImportableURL.parse(text) else { continue }
                let added = (child["date_added"] as? String).flatMap(Int64.init).flatMap(BrowserTime().chromium)
                result.append(ImportedBookmark(title: name.isEmpty ? text : name, url: url, folderPath: path, dateAdded: added))
            case "folder":
                walk(child, path: path + [name], into: &result)
            default:
                continue
            }
        }
    }
}
