public import CmuxNextDaemon
public import CmuxNextHome
import CmuxNextCompat
public import Foundation

/// What the Home list showed last, beyond the conversations themselves (those are `HomeCache`'s):
/// each owner's `home-inbox` rows (order, pins, names), each Chief's avatar and engine, the
/// archived Chiefs and the Chief roster (Main, where each runs). Every one of them is read
/// asynchronously after launch, so without this the first frames drew the list half-loaded:
/// this Mac's old order and pins, the default avatar, no tags, archived Chiefs, then each piece
/// popped in (Lawrence 2026-10-21: "loading stat here is bad on app launch").
public nonisolated struct HomeSidebarLaunchSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = HomeSidebarLaunchSnapshot.currentVersion
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
    public static func key(_ inbox: HomeInboxSource) -> String { inbox.owners.joined(separator: ",") }

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
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return standard(owner: owner, caches: caches)
    }

    /// `<caches>/cmux-home/<owner>/sidebar.json`, beside the conversations' `HomeCache` of the same owner.
    ///
    /// - Parameters:
    ///   - owner: The Chief owner the cache belongs to.
    ///   - caches: The folder that holds the Home caches (the user's Caches folder in the app).
    /// - Returns: The cache at that path.
    public static func standard(owner: String, caches: URL) -> HomeSidebarLaunchCache {
        let component = String(owner.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return HomeSidebarLaunchCache(url: caches.appendingPathComponent("cmux-home/\(component)/sidebar.json"))
    }

    /// The last snapshot for `account`; nil when there is none, it is another account's, or another version's.
    public func load(account: String) -> HomeSidebarLaunchSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(HomeSidebarLaunchSnapshot.self, from: data),
              snapshot.version == HomeSidebarLaunchSnapshot.currentVersion, snapshot.account == account else { return nil }
        state.withLock { $0.written = snapshot }
        return snapshot
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
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil { state.withLock { $0.written = snapshot } }
    }
}
