public import CmuxNextDaemon
public import CmuxNextHome
public import CmuxNextCompat
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

// memory: fixed at most two snapshots of one account's list (the one waiting to be written and the
// last one written), a few KB of JSON each; a newer save replaces the waiting one.
/// The launch snapshot's file: read on a launch lane from `main` with the conversations' `HomeCache`
/// (``HomeListLaunchRead``, a few KB of JSON), written on the files lane at `.bestEffort` after the list
/// changes: one write at a time, the newest snapshot wins, an unchanged one is not written (no timer: the
/// list's changes are the only wakeups). Quit writes the pending one itself (``flush()``).
public nonisolated final class HomeSidebarLaunchCache: Sendable {
    public let url: URL
    /// The lanes the file is written on.
    private let lanes: any MayBlockRunner
    private struct State: Sendable {
        var pending: HomeSidebarLaunchSnapshot?
        var written: HomeSidebarLaunchSnapshot?
        var scheduled = false
    }
    private let state = Mutex(State())

    /// - Parameters:
    ///   - url: the snapshot's file.
    ///   - files: the lanes the file is written on (the app's `work`).
    public init(url: URL, files: any MayBlockRunner) {
        self.url = url
        self.lanes = files
    }

    /// `Caches/cmux-home/<owner>/sidebar.json` in the user's Caches folder, beside the conversations'
    /// `HomeCache` of the same owner.
    public static func standard(owner: String, files: any MayBlockRunner) -> HomeSidebarLaunchCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return standard(owner: owner, caches: caches, files: files)
    }

    /// `<caches>/cmux-home/<owner>/sidebar.json`, beside the conversations' `HomeCache` of the same owner.
    ///
    /// - Parameters:
    ///   - owner: The Chief owner the cache belongs to.
    ///   - caches: The folder that holds the Home caches (the user's Caches folder in the app).
    ///   - files: The lanes the file is written on.
    /// - Returns: The cache at that path.
    public static func standard(owner: String, caches: URL, files: any MayBlockRunner) -> HomeSidebarLaunchCache {
        let component = String(owner.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return HomeSidebarLaunchCache(url: caches.appendingPathComponent("cmux-home/\(component)/sidebar.json"), files: files)
    }

    /// The last snapshot for `account`; nil when there is none, it is another account's, or another version's.
    /// A blocking read: the app reads the file on a launch lane (``HomeListLaunchRead``) and checks the account there.
    public func load(account: String) -> HomeSidebarLaunchSnapshot? {
        guard let snapshot = read(), snapshot.account == account else { return nil }
        return snapshot
    }

    /// The last snapshot of any account; nil when there is none or it is another version's. It is what is on disk
    /// now, so a ``save(_:)`` of the same list writes nothing. A checked blocking read: run it off the main thread.
    public func read() -> HomeSidebarLaunchSnapshot? {
        guard let data = try? Data(blockingContentsOf: url),
              let snapshot = try? JSONDecoder().blockingDecode(HomeSidebarLaunchSnapshot.self, from: data),
              snapshot.version == HomeSidebarLaunchSnapshot.currentVersion else { return nil }
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
        // One coalesced write; a save meanwhile replaces what it writes. Nobody waits for it, and quit
        // flushes the pending snapshot itself, so one not started at quit is dropped.
        lanes.postFiles(.bestEffort, shutdown: .skipOnShutdown) { [self] in flush() }
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
