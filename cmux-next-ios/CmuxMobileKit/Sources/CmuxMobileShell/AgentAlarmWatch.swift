#if os(iOS)
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileNotifications
import Foundation

/// Agent Alarms while cmux runs: the Feed's new asks and errors, and a Mac that stays
/// unreachable, go through the same gate as the pushes (`AgentAlarms`), so an ask seen as its
/// push and again as its Feed row rings once, and no two alarms ring within 30 seconds.
///
/// `ShellTabs` runs `sync` when the Feed's open asks or errors change, the same way
/// `NeedsYouNotices` follows them. An ask that closes (answered here, on the Mac, anywhere)
/// stops its alarm, whichever process rang it.
@MainActor
enum AgentAlarmFeedWatch {
    struct Key: Hashable {
        var open: Set<String>
        var failed: Set<String>
        var live: Bool
    }

    /// How old an error may be and still ring when the Feed first shows it: a reconnect that
    /// reloads an old error is not news.
    static let freshness: TimeInterval = 5 * 60

    /// What the last sync saw; nil before the first live read, which rings only fresh events.
    private static var seen: Set<String>?
    private static var open: Set<String> = []

    static func key(_ store: FeedStore) -> Key {
        Key(open: store.needsYouIDs, failed: failedIDs(store), live: store.syncState == .live)
    }

    static func failedIDs(_ store: FeedStore, now: Date = Date()) -> Set<String> {
        Set(store.items.lazy.filter { $0.kind == .failed && !$0.isDone && now.timeIntervalSince($0.createdAt) < freshness }.map(\.id))
    }

    /// The trigger a Feed event rings, or nil.
    nonisolated static func trigger(_ item: FeedItem) -> AgentAlarmTrigger? {
        switch item.kind {
        case .permission: .permission
        case .question: .question
        case .needsInput: .needsInput
        case .failed: .agentFailed
        case .response, .finished: nil
        }
    }

    /// The event's key, the same as its push's (`AgentAlarmGate.key`): an ask is `ask-<permission id>`.
    nonisolated static func alarmKey(itemID: String) -> String {
        itemID.hasPrefix("ask-") ? "ask:\(itemID.dropFirst(4))" : "feed:\(itemID)"
    }

    static func sync(_ store: FeedStore, alarms: AgentAlarmStore = .live(), now: Date = Date()) async {
        guard store.syncState == .live else { return }
        let current = store.needsYouIDs.union(failedIDs(store, now: now))
        let previous = seen
        seen = current
        // Closed asks stop their alarms: the ones this process saw close, and any alarm the
        // extension rang for an ask the Feed now knows is closed.
        let closedNow = open.subtracting(store.needsYouIDs).map(alarmKey(itemID:))
        open = store.needsYouIDs
        let closedElsewhere = alarms.ledger().alarms.keys.filter { key in
            guard key.hasPrefix("ask:") else { return false }
            return store.isClosedAsk(permissionID: String(key.dropFirst(4)), mac: nil)
        }
        let closed = Set(closedNow).union(closedElsewhere)
        if !closed.isEmpty { AgentAlarms.closed(keys: closed, store: alarms) }

        let added = current.subtracting(previous ?? [])
        let items = added.compactMap(store.item(id:))
            .filter { previous != nil || now.timeIntervalSince($0.createdAt) < 60 }
            .sorted { $0.createdAt < $1.createdAt }
        for item in items {
            guard let trigger = trigger(item) else { continue }
            await AgentAlarms.handle(trigger, key: alarmKey(itemID: item.id), agent: item.agentName,
                                     source: .feed, store: alarms)
        }
    }
}

/// "Mac went offline" (off by default): a Mac this phone was connected to that stays
/// unreachable for `grace` while cmux is open rings once per outage. Only while the app is
/// active, since a backgrounded phone drops its links on purpose.
@MainActor
final class AgentAlarmMacWatch {
    static let shared = AgentAlarmMacWatch()
    /// How long a Mac stays unreachable before it rings.
    var grace: Duration = .seconds(60)

    private var wasConnected: Set<String> = []
    private var pending: [String: Task<Void, Never>] = [:]
    private var active = true

    func update(_ connections: [String: MacConnection], names: [String: String], active: Bool) {
        self.active = active
        guard active else {
            // Backgrounded: the links drop by design. Forget, so returning doesn't ring.
            pending.values.forEach { $0.cancel() }
            pending = [:]
            wasConnected = []
            return
        }
        for (mac, connection) in connections {
            if connection == .connected {
                wasConnected.insert(mac)
                pending.removeValue(forKey: mac)?.cancel()
            } else if wasConnected.contains(mac), pending[mac] == nil {
                let name = names[mac]
                let started = Date()
                let grace = grace
                pending[mac] = Task { [weak self] in
                    do { try await Task.sleep(for: grace) } catch { return }
                    guard let self, self.active, self.pending[mac] != nil else { return }
                    self.pending[mac] = nil
                    self.wasConnected.remove(mac)
                    let key = "mac:\(mac):\(Int(started.timeIntervalSince1970))"
                    await AgentAlarms.handle(.macOffline, key: key, agent: name, source: .macLink)
                }
            }
        }
    }
}
#endif
