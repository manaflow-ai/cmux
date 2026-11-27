import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

extension SidebarMapping {
    /// The subagents of the agent chats in `tabs` (a row passes only its own chat), as acpmux lists them (`recentSubagents`, `subagentsSeen`,
    /// `subagentsRunning`), each with the chat tab a press opens it beside. Nil when no chat has any.
    static func subagents(_ tabs: [TabModel], turns: AgentTurnStateStore = .shared) -> SidebarSubagents? {
        var items: [SidebarSubagent] = []
        var total = 0, running = 0
        var chat: TabID?
        for tab in tabs {
            guard let detail = tab.agentSession.flatMap(turns.detail(for:)),
                  !detail.subagents.isEmpty || detail.subagentsRunning > 0 else { continue }
            let id = TabID(tab.id)
            chat = chat ?? id
            items += detail.subagents.map {
                SidebarSubagent(id: $0.id, title: $0.title, state: SidebarSubagent.State(rawValue: $0.state) ?? .stopped,
                                parent: $0.parent, tab: id)
            }
            total += max(detail.subagentsSeen, detail.subagents.count)
            running += detail.subagentsRunning
        }
        let subagents = SidebarSubagents(items: items, total: total, running: running, chat: chat)
        return subagents.isEmpty ? nil : subagents
    }
}
