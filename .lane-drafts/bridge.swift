// AgentTurnStates.swift (AgentChatDetail) additions:
    /// One of the chat's latest subagents (acpmux `recentSubagents[]`): the sidebar lists them under the chat's row.
    public struct Subagent: Hashable, Sendable {
        public var id: String
        public var parent: String?
        public var title: String?
        /// `running`, `done`, `failed` or `stopped`.
        public var state: String
        public init(id: String, parent: String? = nil, title: String? = nil, state: String) {
            (self.id, self.parent, self.title, self.state) = (id, parent, title, state)
        }
    }
    /// The chat's latest subagents, oldest first (at most 8), and how many it started in all (`subagentsSeen`).
    /// Empty and 0 from an older acpmux.
    public var subagents: [Subagent] = []
    public var subagentsSeen = 0

    static func subagents(_ value: Any?) -> [Subagent] {
        (value as? [Any] ?? []).compactMap { item in
            guard let item = item as? [String: Any], let id = item["id"] as? String, !id.isEmpty,
                  let state = item["state"] as? String else { return nil }
            let text = { (key: String) in (item[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return Subagent(id: id, parent: text("parent"), title: text("title"), state: state)
        }
    }

// SidebarMapping+Subagents.swift (CmuxNextBridge):
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

extension SidebarMapping {
    /// The subagents of every agent chat in the workspace, as acpmux lists them (`recentSubagents`, `subagentsSeen`,
    /// `subagentsRunning`), each with the chat tab a click opens it beside. Nil when no chat has any.
    static func subagents(_ tabs: [TabModel], turns: AgentTurnStateStore = .shared) -> SidebarSubagents? {
        var items: [SidebarSubagent] = []
        var total = 0, running = 0
        for tab in tabs {
            guard let chat = tab.agentSession.flatMap(turns.detail(for:)) else { continue }
            let id = TabID(tab.id)
            items += chat.subagents.map {
                SidebarSubagent(id: $0.id, title: $0.title, state: SidebarSubagent.State(rawValue: $0.state) ?? .stopped,
                                parent: $0.parent, tab: id)
            }
            total += max(chat.subagentsSeen, chat.subagents.count)
            running += chat.subagentsRunning
        }
        let subagents = SidebarSubagents(items: items, total: total, running: running)
        return subagents.isEmpty ? nil : subagents
    }
}
