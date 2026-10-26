import CmuxNextCompat
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

    /// The Chromium that holds the stores: the process-wide runtime (tests pass their own).
    private let runtime: CEFRuntime

    init(runtime: CEFRuntime = .shared) {
        self.runtime = runtime
    }

    /// Why a ``sync(store:treeJSON:onFailure:)`` did not apply.
    public nonisolated enum SyncFailure: Equatable, Sendable {
        /// Chromium refused the tree; the store is forgotten until it reports again.
        case refused
        /// The Chromium Host exited before it answered; the store is forgotten (the next host's stores report again).
        case hostGone
        /// No answer in time: the host may still apply it, and the store stays.
        case noAnswer
        /// Chromium is not running, or no host is attached: nothing was sent.
        case notRunning
    }

    /// How many events each store reported: a sync's refusal forgets the store only when no event
    /// came after the sync was sent (a store that reported again is live again).
    private var reports: [String: UInt64] = [:]

    /// How long a sync waits for the host's answer: a whole tree is applied in one op, which a
    /// busy host can take longer than a site query's ``CEFRuntime/siteReplyTimeout`` for.
    static let syncReplyTimeout: Duration = .seconds(30)

    func arrived(json: String, cachePath: String) {
        guard let profile = Self.profile(ofCachePath: cachePath), let event = CEFBookmarkEvent(json: json) else { return }
        stores[profile, default: []].insert(cachePath)
        reports[cachePath, default: 0] &+= 1
        onEvent?(profile, cachePath, event)
    }

    /// Makes the store's Chromium tree equal to `treeJSON` ({"nodes": [...]},
    /// pre-order), sent in this turn. Chromium's answer is the call's own in
    /// process and the host's REPLY in host mode
    /// (``CEFRuntime/whenSettled(_:label:timeout:then:)``): 1 applied; 0 not
    /// loaded yet (`.loaded` follows); below 0 refused. A refusal, or a host
    /// that exited before it answered (the next host's stores report again),
    /// forgets the store unless it reported after this sync. No answer by
    /// ``syncReplyTimeout`` keeps the store: the host may still apply it.
    /// `onFailure` runs once for anything but 1 or 0.
    public func sync(store: String, treeJSON: String, onFailure: @escaping (SyncFailure) -> Void = { _ in }) {
        guard runtime.shim != nil, runtime.state == .ready else { return onFailure(.notRunning) }
        let reported = reports[store]
        let sent = runtime.sendAsync { shim in shim.bookmarksSync(store, treeJSON) }
        runtime.whenSettled(sent, label: "bookmarks sync", timeout: Self.syncReplyTimeout) { [weak self] settled in
            let failure: SyncFailure
            switch settled {
            case .success(let answer) where answer >= 0: return
            case .success: failure = .refused
            case .failure(.hostGone): failure = .hostGone
            case .failure(.unsent): failure = .notRunning
            case .failure: failure = .noAnswer
            }
            if failure == .refused || failure == .hostGone { self?.forget(store, reported: reported) }
            onFailure(failure)
        }
    }

    /// Forgets `store` when it reported nothing since `reported`.
    private func forget(_ store: String, reported: UInt64?) {
        guard reports[store] == reported else { return }
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
        guard let object = try? JSONSerialization.blockingJSONObject(with: Data(json.utf8)) as? [String: Any],
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
