import CmuxNextDaemon
import Foundation

/// Notifications migration step 1 (plans/cmux-next/feed.md section 9): each
/// local daemon notification the app receives is also posted to the user's
/// feed as a notice, and a tab the app acknowledges marks its notices read
/// there. The daemon ledger stays the source of rings, badges and banners
/// (steps 2 and 3 move them). The app posts because it holds the only cloud
/// credential on the Mac; notifications that arrive while no app runs are not
/// mirrored, and nothing queues while signed out or offline (U5).
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
        /// The daemon tab and workspace ids; nil for a notification without a surface.
        var tab: String?
        var workspace: String?
        /// Who it is from, as the banner subtitle shows it (the tab title).
        var label: String
    }

    typealias Owner = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    private let owner: Owner
    private let isSignedIn: @MainActor () -> Bool
    /// Item ids posted per tab that the app has not read yet.
    private var unread: [String: [String]] = [:]
    /// The newest notification mirrored per tab, and the newest one a read covered.
    private var newest: [String: UInt64] = [:]
    private var readThrough: [String: UInt64] = [:]
    /// Posts and reads in flight; each removes itself when it settles.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Recent posts, reads and failures (for `debug.notifications`).
    private(set) var log: [String] = []
    private static let logLimit = 32

    init(owner: @escaping Owner, isSignedIn: @escaping @MainActor () -> Bool) {
        self.owner = owner
        self.isSignedIn = isSignedIn
    }

    /// The feed.post call for `notice` (path, body).
    nonisolated static func postBody(_ notice: Notice) -> [String: Any] {
        let key = "notify:\(notice.daemonSession):\(notice.notification)"
        var context: [String: Any] = [:]
        if let tab = notice.tab { context["tab"] = String(tab.prefix(128)) }
        if let workspace = notice.workspace { context["workspace"] = String(workspace.prefix(128)) }
        let title = notice.title.isEmpty ? "cmux" : notice.title
        var params: [String: Any] = [
            "type": "notice",
            "kind": "notice",
            "title": cut(title, 200),
            "priority": notice.level == .error ? "high" : "normal",
            "dedupe_key": String(key.prefix(200)),
            "context": context,
            // The owner derives the poster kind from the principal (the user's session today).
            "poster": ["label": cut(notice.label.isEmpty ? "cmux" : notice.label, 80)],
        ]
        if !notice.body.isEmpty { params["body"] = cut(notice.body, 4096) }
        if let tab = notice.tab { params["thread"] = String("tab:\(tab)".prefix(200)) }
        return ["op": "feed.post", "params": params, "idempotency_key": String(key.prefix(200)), "origin": "script"]
    }

    /// Posts `notice` to the feed owner (no-op while signed out).
    func post(_ notice: Notice) {
        guard isSignedIn() else {
            note("skip \(notice.notification): signed out")
            return
        }
        if let tab = notice.tab { newest[tab] = max(newest[tab] ?? 0, notice.notification) }
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

    /// The app read `tab` (acknowledged it in the daemon): its notices so far
    /// become read in the feed, including posts still in flight.
    func read(tab: String) {
        if let newest = newest[tab] { readThrough[tab] = max(readThrough[tab] ?? 0, newest) }
        guard let items = unread.removeValue(forKey: tab), !items.isEmpty else { return }
        sendRead(items)
    }

    /// Waits until no post or read is in flight (tests).
    func drain() async {
        while let task = running.values.first { await task.value }
    }

    private func settled(_ notice: Notice, item: String?) {
        guard let item else { return }
        note("posted \(notice.notification) -> \(item)")
        guard let tab = notice.tab else { return }
        if notice.notification <= readThrough[tab] ?? 0 {
            sendRead([item])
        } else {
            unread[tab, default: []].append(item)
        }
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
