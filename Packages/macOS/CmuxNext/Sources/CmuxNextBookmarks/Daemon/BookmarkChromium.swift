public import CmuxNextBrowser
public import Foundation

/// Chromium's bookmark models and the home daemon's trees (the chrome.bookmarks bridge,
/// plans/cmux-next/bookmarks.md section 4): ids are `bm_<32 hex>` in cmux and that UUID in
/// Chromium, the roots `bar` and `other` on both sides.
public extension BookmarkID {
    /// `bm_<32 hex>` as a lowercase UUID; roots unchanged.
    static func chromium(_ id: String) -> String {
        guard isValid(id) else { return id }
        let hex = Array(id.dropFirst(3))
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-")
    }

    /// A Chromium UUID as `bm_<32 hex>`; roots unchanged.
    static func cmux(chromium id: String) -> String {
        guard !BookmarkRoot.isRoot(id) else { return id }
        return "bm_" + id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// `{"nodes": [...]}` in listing order (each folder before its children), the bridge's sync.
    static func chromiumTree(_ ordered: [BookmarkNode]) -> String {
        let nodes: [[String: Any]] = ordered.map { node in
            var object: [String: Any] = [
                "id": chromium(node.id), "parent": chromium(node.parent),
                "kind": node.isFolder ? "folder" : "url", "title": node.title,
                "added_ms": BookmarkTime.ms(node.created),
            ]
            if let url = node.url { object["url"] = url.absoluteString }
            return object
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["nodes": nodes])) ?? Data("{\"nodes\":[]}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

public extension CEFBookmarkEvent {
    /// The daemon's ops for this Chromium event. A create of an id the daemon has changes
    /// nothing; a delete or move of one it lacks is refused, and the sync after puts Chromium back.
    /// A link whose URL does not parse throws ``BookmarkError/invalidURL``.
    func bookmarkOps(profile: String) throws -> [BookmarkRoutedClient.Op] {
        func id(_ value: String) -> String { BookmarkID.cmux(chromium: value) }
        switch self {
        case .loaded, .reset:
            return []
        case .added(let nodes):
            return try nodes.map { node in
                var url: URL?
                if !node.isFolder {
                    guard let parsed = node.url.flatMap(URL.init(string:)) else { throw BookmarkError.invalidURL }
                    url = parsed
                }
                return .create(id: id(node.id), profile: profile, parent: id(node.parent), index: node.index,
                               folder: node.isFolder, title: node.title, url: url,
                               created: node.addedMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date())
            }
        case .changed(let changed, let title, let url):
            var parsed: URL?
            if let url {
                guard let value = URL(string: url) else { throw BookmarkError.invalidURL }
                parsed = value
            }
            return [.update(id: id(changed), title: title, url: parsed)]
        case .moved(let moved, let parent, let index):
            return [.move(id: id(moved), parent: id(parent), index: index)]
        case .removed(let removed):
            return [.delete(id: id(removed))]
        case .reordered(let parent, let children):
            return children.enumerated().map { index, child in .move(id: id(child), parent: id(parent), index: index) }
        }
    }
}
