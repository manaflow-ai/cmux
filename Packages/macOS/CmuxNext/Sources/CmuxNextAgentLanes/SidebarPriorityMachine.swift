import CmuxNextAgentActivity
public import CmuxNextDaemon
import Foundation

/// Another machine whose agent chats the Priority view ranks (a Cloud VM, an SSH machine, a
/// paired server): its display name and the daemon tree the app already mirrors. Its chats are
/// the agent chat tabs of that tree, and what they need comes from the notices that machine's
/// daemon posts on them (cx-sg1qz: needs input, finished, failed or stopped responding, read
/// again once the chat is seen or answered anywhere). Nothing here asks that machine anything.
@MainActor
public struct SidebarPriorityMachine {
    /// The machine's name as the sidebar shows it (`MachineRegistry.machineName`): each row's
    /// tag, and the name a machine's color is keyed on. Nil for a tree that runs on this Mac (a
    /// server reached at a Unix socket here), whose rows follow this Mac's tag.
    public var name: String?
    public var store: DaemonStore

    public init(name: String?, store: DaemonStore) {
        self.name = name
        self.store = store
    }

    /// The tree is that daemon's current one: connected, past its first snapshot. Only then may
    /// a chat missing from it lose its marks.
    var live: Bool {
        guard case .connected = store.connectionState else { return false }
        return store.isLoaded && !store.isProvisional
    }

    /// One lane per acpmux session the tree's agent chat tabs show, in tree order. A session two
    /// tabs show is one lane, at the stronger of their states.
    func lanes() -> [AgentActivityLane] {
        var order: [String] = []
        var lanes: [String: AgentActivityLane] = [:]
        // The notices' times by id, read from the ledger once and only when a tab's notice has none.
        var ledger: [NotificationID: UInt64]?
        for tab in tabs() {
            guard let ref = tab.agentSession, let session = ref.session, !session.isEmpty else { continue }
            let lane = lane(tab, ref: ref, session: session, ledger: &ledger)
            if let held = lanes[session] {
                if Self.strength(lane) > Self.strength(held) { lanes[session] = lane }
            } else {
                order.append(session)
                lanes[session] = lane
            }
        }
        return order.compactMap { lanes[$0] }
    }

    /// ``lanes()``'s waiting ones (a tab with an unread question or permission prompt), built
    /// from those tabs alone: the first such tab of each session, as ``lanes()`` keeps it.
    func waitingLanes() -> [AgentActivityLane] {
        var ledger: [NotificationID: UInt64]?
        var seen = Set<String>()
        return tabs().compactMap { tab in
            guard tab.hasUnread, tab.notification?.level == .warning, let ref = tab.agentSession,
                  let session = ref.session, !session.isEmpty, seen.insert(session).inserted else { return nil }
            return lane(tab, ref: ref, session: session, ledger: &ledger)
        }
    }

    /// The id of the tree's tab that shows acpmux session `session` (the one its row is made from).
    func tab(showing session: String) -> String? {
        tabs().first { $0.agentSession?.session == session }?.id
    }

    private func tabs() -> [TabModel] {
        store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
    }

    /// The tab's chat as a lane: an unread warning is a question or permission prompt, an unread
    /// error a failed turn or a gone agent, any other unread notice a result nobody has seen. It
    /// has no folder or pull requests, so it is never Red CI (``AgentPriorityChats/failingChecks``).
    private func lane(_ tab: TabModel, ref: AgentSessionRef, session: String,
                      ledger: inout [NotificationID: UInt64]?) -> AgentActivityLane {
        let marker = tab.notification
        let notice = tab.hasUnread ? marker : nil
        let state: AgentActivityLane.State = switch notice?.level {
        case .warning?: .input
        case .error?: .failed
        default: .idle
        }
        let text = notice == nil ? nil : store.notificationText(for: tab)
        // Since the tab's last notice, read or not, so an idle chat ages out like this Mac's.
        var createdAtMs = marker?.createdAtMs
        if createdAtMs == nil, let marker {
            if ledger == nil {
                ledger = Dictionary(store.notifications.compactMap { entry in entry.createdAtMs.map { (entry.notification, $0) } },
                                    uniquingKeysWith: { _, newer in newer })
            }
            createdAtMs = ledger?[marker.notification]
        }
        // A notice posted before the app connected has no time here, nor has a tab with no notice:
        // it counts from when the app first saw it. A mark holds for the notice (`markKey`), not
        // the app's first-seen time. A restarted daemon renumbers its notices, so an id alone can
        // name a new one: the key also holds the notice's time when known, else the daemon boot
        // (`generation`, kept through a disconnect) that numbered it.
        let boot = "g" + (store.identity?.generation.rawValue ?? "-")
        let key = marker.map { "n\($0.notification.rawValue)@" + (createdAtMs.map(String.init) ?? boot) } ?? "none"
        let since = createdAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Self.firstSeen("\(session)#\(key)")
        let title = tab.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentActivityLane(id: session, name: session, title: title.isEmpty ? ref.harness ?? session : title, peer: name,
                                 parent: nil, state: state, since: since,
                                 error: state == .failed ? text : nil, harness: ref.harness, step: state == .failed ? nil : text,
                                 unread: notice != nil && state == .idle, markKey: key)
    }

    /// When the app first saw each tab's notice (or a tab with none) that has no time, by session
    /// and notice: only how long an idle row stays listed reads it (bounded).
    private static var seen: [String: Date] = [:]

    private static func firstSeen(_ key: String) -> Date {
        if let date = seen[key] { return date }
        if seen.count >= 4096 { seen.removeAll() }
        let now = Date()
        seen[key] = now
        return now
    }

    private static func strength(_ lane: AgentActivityLane) -> Int {
        switch lane.state {
        case .input: 3
        case .failed, .lost: 2
        case .idle, .working: lane.unread ? 1 : 0
        }
    }
}
