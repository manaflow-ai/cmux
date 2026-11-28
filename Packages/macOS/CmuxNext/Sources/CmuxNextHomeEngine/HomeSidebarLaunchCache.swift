public import CmuxNextDaemon
public import CmuxNextHomeModel
import CmuxNextCompat
public import Foundation

/// What the Home list showed last, beyond the conversations themselves (those are `HomeCache`'s):
/// each owner's `home-inbox` rows (order, pins, names), each Chief's avatar and engine, the
/// archived Chiefs and the Chief roster (Main, where each runs). Every one of them is read
/// asynchronously after launch, so without this the first frames drew the list half-loaded:
/// this Mac's old order and pins, the default avatar, no tags, archived Chiefs, then each piece
/// popped in (Lawrence 2026-10-21: "loading stat here is bad on app launch").
public nonisolated struct HomeSidebarLaunchSnapshot: Codable, Equatable, Sendable {
    /// The snapshot's shape (``HomeSidebarLaunchCache/fingerprint(of:)`` of an empty snapshot): a
    /// cache written by a build whose snapshot had other fields, or fields of other types, is
    /// discarded and rebuilt, with no version to bump by hand.
    public static var schema: String { HomeSidebarLaunchCache.fingerprint(of: HomeSidebarLaunchSnapshot(account: "")) }
    /// The pin account the list was shown for (`HomeService.pinAccount`): another account's list is never shown.
    public var account: String
    /// Each inbox owner's last reply, by its owners key ("local", "cloud").
    public var replies: [String: HomeInboxRequest.Response] = [:]
    public var chiefAvatars: [String: HomeChiefAvatar] = [:]
    public var chiefHarnesses: [String: String] = [:]
    public var archivedChiefs: Set<String> = []
    public var roster: HomeChiefRoster?

    public init(account: String, replies: [String: HomeInboxRequest.Response] = [:], chiefAvatars: [String: HomeChiefAvatar] = [:],
                chiefHarnesses: [String: String] = [:], archivedChiefs: Set<String> = [], roster: HomeChiefRoster? = nil) {
        self.account = account
        self.replies = replies
        self.chiefAvatars = chiefAvatars
        self.chiefHarnesses = chiefHarnesses
        self.archivedChiefs = archivedChiefs
        self.roster = roster
    }

    /// The key an inbox's reply is kept under.
    public static func key(_ inbox: HomeInboxSource) -> String {
        dockRule("dock.launch_cache_inbox_key", ["owners": inbox.owners], fallback: inbox.owners.joined(separator: ","))
    }

    /// Gives each inbox that has not answered yet its last reply, so the list's first frame is the
    /// list as it was. An owner's answer then replaces it in place.
    @MainActor public func seed(_ inboxes: [HomeInboxSource]) {
        for inbox in inboxes { inbox.seed(replies[Self.key(inbox)]) }
    }
}

/// The launch snapshot's file: read synchronously before the Home list's first frame (a few KB of
/// JSON, like `HomeCache.load`), written off the main actor after the list changes: one write at a
/// time, the newest snapshot wins, an unchanged one is not written (no timer: the list's changes
/// are the only wakeups).
public nonisolated final class HomeSidebarLaunchCache: Sendable {
    public let url: URL
    /// What the file holds: the snapshot under the schema of the build that wrote it.
    private struct File: Codable {
        var schema: String
        var snapshot: HomeSidebarLaunchSnapshot
    }
    private struct State: Sendable {
        var pending: HomeSidebarLaunchSnapshot?
        var written: HomeSidebarLaunchSnapshot?
        var scheduled = false
    }
    private let state = Mutex(State())

    public init(url: URL) {
        self.url = url
    }

    /// `Caches/cmux-home/<owner>/sidebar.json` in the user's Caches folder, beside the conversations'
    /// `HomeCache` of the same owner.
    public static func standard(owner: String) -> HomeSidebarLaunchCache {
        let caches = NextSupport.cachesDirectory()
        return standard(owner: owner, caches: caches)
    }

    /// `<caches>/cmux-home/<owner>/sidebar.json`, beside the conversations' `HomeCache` of the same owner.
    ///
    /// - Parameters:
    ///   - owner: The Chief owner the cache belongs to.
    ///   - caches: The folder that holds the Home caches (the user's Caches folder in the app).
    /// - Returns: The cache at that path.
    public static func standard(owner: String, caches: URL) -> HomeSidebarLaunchCache {
        let path: String = dockRule("dock.launch_cache_path", ["owner": owner], fallback: "cmux-home/-/sidebar.json")
        return HomeSidebarLaunchCache(url: caches.appendingPathComponent(path))
    }

    /// A stable fingerprint of a value's stored shape: each stored property's name and full type
    /// name (`Mirror`), hashed with FNV-1a 64 (the same in every process, unlike `Hasher`). Adding,
    /// removing, renaming or retyping a stored property changes it; a field added inside a nested
    /// type does not (a new required one already fails the decode).
    ///
    /// - Parameter sample: Any value of the type (its property values are not read, only their types).
    /// - Returns: 16 lowercase hex digits (`dock.launch_cache_fingerprint`; the shape string stays
    ///   here, since only Swift reflection can read it).
    public static func fingerprint(of sample: Any) -> String {
        var shape = String(reflecting: type(of: sample))
        for child in Mirror(reflecting: sample).children {
            shape += "|\(child.label ?? "_"):\(String(reflecting: type(of: child.value)))"
        }
        return dockRule("dock.launch_cache_fingerprint", ["shape": shape], fallback: "")
    }

    /// The last snapshot for `account`; nil when there is none, it is another account's, or another schema's.
    public func load(account: String) -> HomeSidebarLaunchSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              Self.accepts(file, account: account) else { return nil }
        let snapshot = file.snapshot
        state.withLock { $0.written = snapshot }
        return snapshot
    }

    /// Whether a read file is used: its schema and account are this build's and `account`.
    private static func accepts(_ file: File, account: String) -> Bool {
        let request = ["schema": HomeSidebarLaunchSnapshot.schema, "fileSchema": file.schema, "account": account, "fileAccount": file.snapshot.account]
        return dockRule("dock.launch_cache_load_accepts", request, fallback: false)
    }

    /// Keeps `snapshot`, written by one background write (the last one wins); an unchanged one is not written.
    public func save(_ snapshot: HomeSidebarLaunchSnapshot) {
        let schedule: Bool = state.withLock { state in
            guard snapshot != state.written else { state.pending = nil; return false }
            state.pending = snapshot
            if state.scheduled { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        // task-owner: one coalesced write; ends after it (a save meanwhile replaces what it writes)
        Task.detached(priority: .utility) { [self] in flush() }
    }

    /// Writes the pending snapshot now (app quit, tests). The file is written outside the lock.
    public func flush() {
        let snapshot: HomeSidebarLaunchSnapshot? = state.withLock { state in
            state.scheduled = false
            defer { state.pending = nil }
            return state.pending
        }
        guard let snapshot, let data = try? JSONEncoder().encode(File(schema: HomeSidebarLaunchSnapshot.schema, snapshot: snapshot)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil { state.withLock { $0.written = snapshot } }
    }
}
