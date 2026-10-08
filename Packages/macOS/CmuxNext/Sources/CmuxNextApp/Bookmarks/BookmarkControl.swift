import CmuxNextBookmarks
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `bookmark.list {profile?, text?, folder?, limit?}` for `cmux bookmark
/// list` and `cmux bookmark search <text>`, and `debug.bookmarks` (the bar
/// and star of a tab, for verification).
enum BookmarkControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor("bookmark.list") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(list(services, call.params))
            },
            .mainActor("debug.bookmarks") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(debug(services, tab: call.params["tab"]?.stringValue))
            },
        ]
    }

    @MainActor
    static func list(_ services: AppServices, _ params: [String: JSONValue]) -> JSONValue {
        let profile = params["profile"]?.stringValue ?? BookmarkResolver(services: services).profile(.init())
        let tree = services.bookmarks.tree(profile)
        var nodes: [BookmarkNode]
        if let text = params["text"]?.stringValue, !text.isEmpty {
            nodes = BookmarkSearch.results(tree, text: text)
        } else if let folder = params["folder"]?.stringValue {
            nodes = tree.children(of: folder)
        } else {
            nodes = tree.ordered
        }
        if let limit = params["limit"]?.intValue { nodes = Array(nodes.prefix(max(1, limit))) }
        return .object([
            "profile": .string(profile),
            "storage": .string(services.bookmarks.usesDaemon ? "daemon" : "file"),
            "bookmarks": .array(nodes.map { json($0, tree: tree) }),
        ])
    }

    static func json(_ node: BookmarkNode, tree: BookmarkTree) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(node.id), "kind": .string(node.kind.rawValue), "parent": .string(node.parent),
            "title": .string(node.title), "index": .number(Double(tree.index(of: node.id) ?? 0)),
            "path": .string(tree.folderPath(of: node.id).joined(separator: "/")),
            "created": .string(ISO8601DateFormatter().string(from: node.created)),
        ]
        if let url = node.url { object["url"] = .string(url.absoluteString) }
        if let used = node.lastUsed { object["last_used"] = .string(ISO8601DateFormatter().string(from: used)) }
        if let source = node.sourceKey { object["source_key"] = .string(source) }
        return .object(object)
    }

    @MainActor
    static func debug(_ services: AppServices, tab: String?) -> JSONValue {
        let key = tab ?? services.windows.active?.focusedPane?.selectedTab?.id
        var object: [String: JSONValue] = [
            "bar_shown": .bool(services.bookmarks.isBarShown),
            "storage": .string(services.bookmarks.usesDaemon ? "daemon" : "file"),
        ]
        if let key, let entry = services.cache.existingBrowser(key) {
            object["tab"] = .string(key)
            object["profile"] = .string(services.bookmarks.profile(ofTab: key))
            object["star"] = .string(String(describing: entry.chrome.addressBar.bookmarkStarState))
            object["bar_attached"] = .bool(entry.chrome.accessoryView != nil)
            if let bar = services.bookmarks.bar(ofTab: key) {
                object["bar_visible"] = .array(bar.visibleTitles.map(JSONValue.string))
                object["bar_overflow"] = .array(bar.overflowTitles.map(JSONValue.string))
            }
        }
        return .object(object)
    }
}
