import CmuxNextDaemon
import Foundation

/// Notifications migration step 1 (plans/cmux-next/feed.md section 9): a
/// local daemon notification that would alert the user on this Mac is also
/// posted to the user's feed as a notice, and a tab the user reads marks its
/// notices read there. The daemon ledger stays the source of rings, badges
/// and banners (steps 2 and 3 move them). The app posts because it holds the
/// only cloud credential on the Mac; notifications that arrive while no app
/// runs are not mirrored, and nothing queues while signed out or offline (U5).
///
/// What leaves the Mac is limited by `feed.mirrorNotifications` (the caller
/// filters by source), `FeedSecretScrubber` (known secret shapes become
/// `[redacted]`), a fixed poster label (never the tab title, which can hold a
/// command line), per-tab coalescing (one post in flight per tab, the latest
/// waiting one wins) and a client cap of `maxPostsPerMinute`.
///
/// One notice per daemon notification: the dedupe key and the idempotency
/// key are `notify:<daemon session>:<notification id>`, so two apps on one
/// daemon, or a retried request, give one item.
@MainActor
final class FeedNotificationBridge {
    /// One daemon notification, as the bridge posts it.
    struct Notice: Equatable {
        var notification: UInt64
        /// The daemon's stable session UUID (`identify.session`).
        var daemonSession: String
        var title: String
        var body: String
        var level: NotificationLevel
        /// The daemon tab and workspace ids (only notifications with a tab are mirrored).
        var tab: String
        var workspace: String?
        /// The source name shown as the poster (`agent`, `terminal`, `cli`).
        var label: String
    }

    typealias Owner = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    /// Client cap on posts: terminal spam must not use up the owner's per-poster limit.
    static let maxPostsPerMinute = 30

    private let owner: Owner
    private let isSignedIn: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    /// Item ids posted per tab that the user has not read yet.
    private var unread: [String: [String]] = [:]
    /// The newest notification mirrored per tab, and the newest one a read covered.
    private var newest: [String: UInt64] = [:]
    private var readThrough: [String: UInt64] = [:]
    /// Tabs with a post in flight, and the latest notice waiting behind it.
    private var postingTabs: Set<String> = []
    private var waiting: [String: Notice] = [:]
    private var minute: (start: Date, count: Int)?
    /// Posts and reads in flight; each removes itself when it settles.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Recent posts, reads and failures (for `debug.notifications`).
    private(set) var log: [String] = []
    private static let logLimit = 32

    init(owner: @escaping Owner, isSignedIn: @escaping @MainActor () -> Bool, now: @escaping @MainActor () -> Date = Date.init) {
        self.owner = owner
        self.isSignedIn = isSignedIn
        self.now = now
    }

    /// The feed.post call for `notice` (path, body), scrubbed of known secret shapes.
    nonisolated static func postBody(_ notice: Notice) -> [String: Any] {
        let key = "notify:\(notice.daemonSession):\(notice.notification)"
        var context: [String: Any] = ["tab": String(notice.tab.prefix(128))]
        if let workspace = notice.workspace { context["workspace"] = String(workspace.prefix(128)) }
        let title = FeedSecretScrubber.scrub(notice.title)
        var params: [String: Any] = [
            "type": "notice",
            "kind": "notice",
            "title": cut(title.isEmpty ? "cmux" : title, 200),
            "priority": notice.level == .error ? "high" : "normal",
            "dedupe_key": String(key.prefix(200)),
            "thread": String("tab:\(notice.tab)".prefix(200)),
            "context": context,
            // The owner derives the poster kind from the principal (the user's session today).
            "poster": ["label": cut(notice.label.isEmpty ? "cmux" : notice.label, 80)],
        ]
        let body = FeedSecretScrubber.scrub(notice.body)
        if !body.isEmpty { params["body"] = cut(body, 4096) }
        return ["op": "feed.post", "params": params, "idempotency_key": String(key.prefix(200)), "origin": "script"]
    }

    /// Posts `notice` to the feed owner (no-op while signed out). While a post
    /// for the same tab is in flight, the notice waits; a newer one replaces it.
    func post(_ notice: Notice) {
        guard isSignedIn() else {
            note("skip \(notice.notification): signed out")
            return
        }
        newest[notice.tab] = max(newest[notice.tab] ?? 0, notice.notification)
        if postingTabs.contains(notice.tab) {
            if let replaced = waiting[notice.tab] { note("coalesced \(replaced.notification)") }
            waiting[notice.tab] = notice
            return
        }
        send(notice)
    }

    /// The user read `tab`: its notices so far become read in the feed,
    /// including posts still in flight.
    func read(tab: String) {
        if let newest = newest[tab] { readThrough[tab] = max(readThrough[tab] ?? 0, newest) }
        if let items = unread.removeValue(forKey: tab), !items.isEmpty { sendRead(items) }
        forgetIfIdle(tab)
    }

    /// Waits until no post or read is in flight (tests).
    func drain() async {
        while let task = running.values.first { await task.value }
    }

    /// Per-tab entries held (tests: they must not grow without bound).
    var trackedTabs: Int { Set(newest.keys).union(readThrough.keys).union(unread.keys).count }

    private func send(_ notice: Notice) {
        let date = now()
        if let current = minute, date.timeIntervalSince(current.start) < 60 {
            guard current.count < Self.maxPostsPerMinute else {
                note("skip \(notice.notification): over \(Self.maxPostsPerMinute) posts per minute")
                return
            }
            minute = (current.start, current.count + 1)
        } else {
            minute = (date, 1)
        }
        postingTabs.insert(notice.tab)
        let body = Self.postBody(notice)
        let id = UUID()
        // task-owner: FeedNotificationBridge.running: one feed.post per daemon notification; the entry is removed when it settles.
        running[id] = Task { [weak self, owner] in
            let item: String?
            do {
                let reply = try await owner("v1/ops", body)
                item = ((reply["value"] as? [String: Any])?["item"] as? [String: Any])?["id"] as? String
                if item == nil { self?.note("post \(notice.notification): no item in reply") }
            } catch {
                item = nil
                self?.note("post \(notice.notification) failed: \(Self.describe(error))")
            }
            self?.running[id] = nil
            self?.settled(notice, item: item)
        }
    }

    private func settled(_ notice: Notice, item: String?) {
        let tab = notice.tab
        postingTabs.remove(tab)
        if let item {
            note("posted \(notice.notification) -> \(item)")
            if notice.notification <= readThrough[tab] ?? 0 {
                sendRead([item])
            } else {
                unread[tab, default: []].append(item)
            }
        }
        if let next = waiting.removeValue(forKey: tab) {
            send(next)
        } else {
            forgetIfIdle(tab)
        }
    }

    /// Drops a tab's bookkeeping once everything it posted is read and nothing is in flight.
    private func forgetIfIdle(_ tab: String) {
        guard !postingTabs.contains(tab), waiting[tab] == nil, unread[tab]?.isEmpty ?? true,
              (newest[tab] ?? 0) <= (readThrough[tab] ?? 0) else { return }
        newest[tab] = nil
        readThrough[tab] = nil
        unread[tab] = nil
    }

    private func sendRead(_ items: [String]) {
        let body: [String: Any] = ["op": "feed.read", "params": ["items": items], "idempotency_key": UUID().uuidString, "origin": "user"]
        note("read \(items.joined(separator: ","))")
        let id = UUID()
        // task-owner: FeedNotificationBridge.running: one feed.read; a failure only leaves the notice unread in the feed.
        running[id] = Task { [weak self, owner] in
            do { _ = try await owner("v1/ops", body) } catch { self?.note("read failed: \(Self.describe(error))") }
            self?.running[id] = nil
        }
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    nonisolated private static func cut(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max))
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        if case let FeedServiceError.owner(code, _) = error { return code }
        return String(describing: error).prefix(120).description
    }
}
