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
        for tab in store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs) {
            guard let ref = tab.agentSession, let session = ref.session, !session.isEmpty else { continue }
            let lane = lane(tab, ref: ref, session: session)
            if let held = lanes[session] {
                if Self.strength(lane) > Self.strength(held) { lanes[session] = lane }
            } else {
                order.append(session)
                lanes[session] = lane
            }
        }
        return order.compactMap { lanes[$0] }
    }

    /// The tab's chat as a lane: an unread warning is a question or permission prompt, an unread
    /// error a failed turn or a gone agent, any other unread notice a result nobody has seen. It
    /// has no folder or pull requests, so it is never Red CI (``AgentPriorityChats/failingChecks``).
    private func lane(_ tab: TabModel, ref: AgentSessionRef, session: String) -> AgentActivityLane {
        let notice = tab.hasUnread ? tab.notification : nil
        let state: AgentActivityLane.State = switch notice?.level {
        case .warning?: .input
        case .error?: .failed
        default: .idle
        }
        let text = notice == nil ? nil : store.notificationText(for: tab)
        let createdAtMs = notice.flatMap { marker in
            marker.createdAtMs ?? store.notifications.last { $0.notification == marker.notification }?.createdAtMs
        }
        // A notice posted before the app connected has no time here: it counts from when the app
        // first saw it, so each new notice is a new state (a read or snooze mark on the last one
        // no longer holds).
        let since = createdAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            ?? notice.map { Self.firstSeen("\(session)#\($0.notification.rawValue)") }
        let title = tab.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentActivityLane(id: session, name: session, title: title.isEmpty ? ref.harness ?? session : title, peer: name,
                                 parent: nil, state: state, since: since,
                                 error: state == .failed ? text : nil, harness: ref.harness, step: state == .failed ? nil : text,
                                 unread: notice != nil && state == .idle)
    }

    /// When the app first saw each untimed notice, by session and notice (bounded).
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
