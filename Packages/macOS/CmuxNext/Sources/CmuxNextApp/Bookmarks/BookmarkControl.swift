import CmuxNextBookmarks
import CmuxNextBrowserImport
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `bookmark.list {profile?, text?, folder?, limit?}` for `cmux bookmark
/// list` and `cmux bookmark search <text>`: the home daemon's rows, each with
/// its index and path from the stored tree; `loaded` is true when the daemon
/// answered (false, with no rows, before it serves bookmarks).
/// `bookmark.importSources {browser, source?}`: the profiles
/// `bookmark.importFromBrowser` with the same params would import, each with
/// the `source_key` its folder gets. `debug.bookmarks` (the bar and star of a
/// tab, for verification).
enum BookmarkControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            // Off the main actor: the rows (a search's too) come from the home daemon (cmux-bookmarks-ops).
            .async("bookmark.list") { [weak services] call in
                guard let services else { return .null }
                return try await list(services, call.params)
            },
            // Off the main actor: detection reads the browsers' data folders, the
            // same read-only pass as the import picker (no Keychain, no writes).
            .async("bookmark.importSources") { call in
                guard let browser = call.params["browser"]?.stringValue, !browser.isEmpty else {
                    throw ControlError.invalidParams("bookmark.importSources needs `browser`.")
                }
                let source = call.params["source"]?.stringValue
                let found = await Task.detached {
                    BookmarkBrowserImport.sources(environment: BookmarkBrowserImport.liveEnvironment())
                }.value
                return importSources(found, browser: browser, source: source)
            },
            .mainActor("debug.bookmarks") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(debug(services, tab: call.params["tab"]?.stringValue))
            },
        ]
    }

    /// The rows for `params`: a search's matches (`text`), else a folder's children (`folder`),
    /// else every node, read from the home daemon with their places; the main actor waits on nothing.
    @MainActor
    static func list(_ services: AppServices, _ params: [String: JSONValue]) async throws -> JSONValue {
        let profile = params["profile"]?.stringValue ?? BookmarkResolver(services: services).profile(.init())
        let limit = params["limit"]?.intValue.map { max(1, $0) }
        guard services.bookmarks.usesDaemon else { return answer(profile, loaded: false, nodes: []) }
        let routed = services.bookmarks.routed
        do {
            var nodes: [BookmarkNode]
            if let text = params["text"]?.stringValue, !text.isEmpty {
                nodes = try await routed.search(text, profile: profile, limit: limit, places: true)
            } else if let folder = params["folder"]?.stringValue {
                nodes = try await routed.children(of: folder, profile: profile, limit: limit ?? 20_000, places: true)
            } else {
                nodes = try await routed.list(profile: profile, places: true)
            }
            if let limit { nodes = Array(nodes.prefix(limit)) }
            return answer(profile, loaded: true, nodes: nodes)
        } catch {
            throw ControlError(code: "unavailable", message: BookmarkAppStrings.failure(error))
        }
    }

    static func answer(_ profile: String, loaded: Bool, nodes: [BookmarkNode]) -> JSONValue {
        .object(["profile": .string(profile), "storage": .string("daemon"), "loaded": .bool(loaded),
                 "bookmarks": .array(nodes.map(json))])
    }

    /// What an import of `browser` (and `source`) would read: the same
    /// ``BookmarkBrowserImport/match(_:browser:source:)`` as the import, and
    /// `source_key` is the key the import stores on the profile's folder.
    nonisolated static func importSources(_ sources: [BrowserSource], browser: String, source: String?) -> JSONValue {
        let profiles = BookmarkBrowserImport.match(sources, browser: browser, source: source)
        return .object(["sources": .array(profiles.map { profile in
            .object(["source_key": .string(profile.id), "browser": .string(profile.browser.rawValue),
                     "folder": .string(profile.directoryName), "name": .string(profile.displayName)])
        })])
    }

    /// One row; `index` and `path` are the daemon's (its place in the stored tree).
    static func json(_ node: BookmarkNode) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(node.id), "kind": .string(node.kind.rawValue), "parent": .string(node.parent),
            "title": .string(node.title), "index": .number(Double(node.index)),
            "path": .string(node.path.joined(separator: "/")),
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
            "storage": .string("daemon"),
        ]
        if let key, let entry = services.cache.existingBrowser(key) {
            object["tab"] = .string(key)
            object["profile"] = .string(services.bookmarks.profile(ofTab: key))
            object["star"] = .string(String(describing: entry.state.bookmarkStar))
            object["bar_attached"] = .bool(entry.state.accessory != nil)
            if let bar = services.bookmarks.bar(ofTab: key) {
                object["bar_visible"] = .array(bar.visibleTitles.map(JSONValue.string))
                object["bar_overflow"] = .array(bar.overflowTitles.map(JSONValue.string))
            }
        }
        return .object(object)
    }
}
