public import CmuxNextAgentActivity
public import CmuxNextApps
import CmuxNextSidebar
public import Foundation

extension AgentActivityLane {
    /// The lane as `agent_chat.list` gives it to a script (``AgentChatSummary``).
    public var agentChat: AgentChatSummary {
        AgentChatSummary(id: id, title: title, harness: harness, state: state.rawValue, unread: unread,
                         project: project ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, cwd: cwd,
                         workspace: workspaceID, machine: peer, step: step, error: error, since: since,
                         updatedAt: updatedAt, createdAt: createdAt, pullRequests: pullRequests)
    }
}

extension AgentLaneStore {
    /// The chats `agent_chat.list` answers: every lane the store holds (this Mac's and its peers'),
    /// or, with the capture tunable `sidebar.laneFixture` on, the sample chats
    /// (``SidebarLaneFixture/chats(now:)``), so a capture slot with no agents shows a thread list.
    public func agentChats(now: Date = Date()) -> [AgentChatSummary] {
        let chats = SidebarTunables.laneFixture.value ? SidebarLaneFixture.chats(now: now) : Array(lanes.values)
        return chats.map(\.agentChat)
    }
}

extension AgentChatAppOps {
    /// `agent_chat.list` over this Mac's lane store (``AgentLaneStore/agentChats(now:)``), for the
    /// app's provider channel: the agent chats the sidebar shows, for a customize section's thread list.
    @MainActor public static func sidebarChats(_ store: AgentLaneStore = .shared) -> AgentChatAppOps {
        AgentChatAppOps { store.agentChats() }
    }
}
