public import Foundation

/// The chrome.bookmarks bridge (plans/cmux-next/bookmarks.md section 4; fork
/// API 22). cmux owns the bookmark tree; Chromium's model of every persistent
/// Chromium profile caches it, so extensions see cmux's bookmarks and their
/// changes reach cmux. One cmux profile can have several Chromium stores (its
/// own and remote-localhost ones, `CEFProfileStorage`); each is synced alone.
/// Nodes carry Chromium ids (lowercase UUIDs); the roots are `bar` and `other`.
public final class CEFBookmarkBridge {
    public static let shared = CEFBookmarkBridge()

    /// A store's Chromium event, for the cmux profile the store belongs to.
    /// `.loaded` and `.reset` ask for `sync(store:treeJSON:)`.
    public var onEvent: ((_ profile: BrowserProfileID, _ store: String, _ event: CEFBookmarkEvent) -> Void)?

    /// Stores that reported, per cmux profile.
    public private(set) var stores: [BrowserProfileID: Set<String>] = [:]

    func arrived(json: String, cachePath: String) {
        guard let profile = Self.profile(ofCachePath: cachePath), let event = CEFBookmarkEvent(json: json) else { return }
        stores[profile, default: []].insert(cachePath)
        onEvent?(profile, cachePath, event)
    }

    /// Makes the store's Chromium tree equal to `treeJSON` ({"nodes": [...]},
    /// pre-order). 1 applied; 0 not loaded yet (`.loaded` follows); -1 refused,
    /// also when Chromium is not running or has no bridge.
    @discardableResult
    public func sync(store: String, treeJSON: String) -> Int32 {
        let runtime = CEFRuntime.shared
        guard let shim = runtime.shim, runtime.state == .ready else { return -1 }
        let result = shim.bookmarksSync(store, treeJSON)
        if result < 0 { forget(store) }
        return result
    }

    private func forget(_ store: String) {
        for profile in stores.keys { stores[profile]?.remove(store) }
    }

    /// `<root>/Profile-<uuid>` or `<root>/Profile-<uuid>-m-<machine>`.
    static func profile(ofCachePath path: String) -> BrowserProfileID? {
        let name = URL(filePath: path).lastPathComponent
        guard name.hasPrefix("Profile-") else { return nil }
        let uuid = name.dropFirst("Profile-".count).prefix(36)
        return UUID(uuidString: String(uuid)).map(BrowserProfileID.init(rawValue:))
    }
}

/// One `cmux_bookmarks_observe` event.
public enum CEFBookmarkEvent: Equatable {
    case loaded
    case reset
    case added([CEFBookmarkNode])
    case changed(id: String, title: String, url: String?)
    case moved(id: String, parent: String, index: Int)
    case removed(id: String)
    case reordered(parent: String, children: [String])

    init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let op = object["op"] as? String else { return nil }
        let id = object["id"] as? String
        switch op {
        case "loaded": self = .loaded
        case "reset": self = .reset
        case "added":
            self = .added(((object["nodes"] as? [[String: Any]]) ?? []).compactMap(CEFBookmarkNode.init))
        case "changed":
            guard let id else { return nil }
            self = .changed(id: id, title: object["title"] as? String ?? "", url: object["url"] as? String)
        case "moved":
            guard let id, let parent = object["parent"] as? String, let index = object["index"] as? Int else { return nil }
            self = .moved(id: id, parent: parent, index: index)
        case "removed":
            guard let id else { return nil }
            self = .removed(id: id)
        case "reordered":
            guard let parent = object["parent"] as? String, let children = object["children"] as? [String] else { return nil }
            self = .reordered(parent: parent, children: children)
        default: return nil
        }
    }
}

/// A Chromium bookmark node as the bridge reports it.
public struct CEFBookmarkNode: Equatable {
    public var id: String
    public var parent: String
    public var index: Int
    public var isFolder: Bool
    public var title: String
    public var url: String?
    public var addedMs: Double?

    init?(_ object: [String: Any]) {
        guard let id = object["id"] as? String, let parent = object["parent"] as? String,
              let index = object["index"] as? Int, let kind = object["kind"] as? String else { return nil }
        self.id = id
        self.parent = parent
        self.index = index
        isFolder = kind == "folder"
        title = object["title"] as? String ?? ""
        url = object["url"] as? String
        addedMs = object["added_ms"] as? Double
    }
}
