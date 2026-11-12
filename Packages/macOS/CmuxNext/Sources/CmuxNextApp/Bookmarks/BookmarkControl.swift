import CmuxNextBookmarks
import CmuxNextBrowserImport
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `bookmark.list {profile?, text?, folder?, limit?}` for `cmux bookmark
/// list` and `cmux bookmark search <text>`; its `loaded` says the tree is the
/// stored one, not the empty placeholder shown until the daemon answers.
/// `bookmark.importSources {browser, source?}`: the profiles
/// `bookmark.importFromBrowser` with the same params would import, each with
/// the `source_key` its folder gets. `debug.bookmarks` (the bar and star of a
/// tab, for verification).
enum BookmarkControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            // Off the main actor: a search (`text`) runs on the home daemon (cmux-bookmarks-ops).
            .async("bookmark.list") { [weak services] call in
                let params = call.params
                guard let services else { return .null }
                guard let text = params["text"]?.stringValue, !text.isEmpty else { return await list(services, params) }
                return try await search(services, params, text: text)
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

    /// `text`'s matches, found by the home daemon; the main actor waits on nothing.
    @MainActor
    static func search(_ services: AppServices, _ params: [String: JSONValue], text: String) async throws -> JSONValue {
        let profile = params["profile"]?.stringValue ?? BookmarkResolver(services: services).profile(.init())
        do {
            let found = try await services.bookmarks.routed.search(text, profile: profile, limit: params["limit"]?.intValue.map { max(1, $0) })
            return list(services, params, profile: profile, nodes: found)
        } catch {
            throw ControlError(code: "unavailable", message: BookmarkAppStrings.failure(error))
        }
    }

    /// The answer for `profile`; `nodes` are a search's results (else the folder's children, or every node).
    @MainActor
    static func list(_ services: AppServices, _ params: [String: JSONValue], profile chosen: String? = nil,
                     nodes found: [BookmarkNode]? = nil) -> JSONValue {
        let profile = chosen ?? params["profile"]?.stringValue ?? BookmarkResolver(services: services).profile(.init())
        // `tree` asks the daemon the first time, so read it before `isLoaded`.
        let tree = services.bookmarks.tree(profile)
        var nodes: [BookmarkNode]
        if let found {
            nodes = found
        } else if let folder = params["folder"]?.stringValue {
            nodes = tree.children(of: folder)
        } else {
            nodes = tree.ordered
        }
        if let limit = params["limit"]?.intValue { nodes = Array(nodes.prefix(max(1, limit))) }
        return .object([
            "profile": .string(profile),
            "storage": .string(services.bookmarks.usesDaemon ? "daemon" : "file"),
            "loaded": .bool(services.bookmarks.isLoaded(profile)),
            "bookmarks": .array(nodes.map { json($0, tree: tree) }),
        ])
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
