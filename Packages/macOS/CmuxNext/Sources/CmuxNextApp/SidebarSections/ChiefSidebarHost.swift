import CmuxHomeCore
import CmuxNextAgentLanes
import CmuxNextHomeEngine

extension ChiefSidebar.Host {
    /// The App's Chief for the sidebar item: Home's Chief conversation, the Chief host's tabs and
    /// workspaces, and whether Home shows the conversation unread.
    static func app(_ services: AppServices) -> Self {
        .init(conversation: { TopHomePageView.chief(services.home) }, chiefHost: { services.agentTabs.chiefHost },
              tab: { services.agentTabs.tab(showing: $0, host: $1) }, reveal: { services.revealTab($0) },
              openWorkspace: { try AgentSessionWorkspace.open(session: $0, name: nil, cwd: nil, host: $1, services: services) },
              unread: { unread(chief: TopHomePageView.chief(services.home), in: services.home.groupMuting) })
    }

    /// Whether Home's list shows the Chief's conversation `chief` unread, as `home` (the source behind
    /// ``HomeService/unreadConversations``) maps it. Read in the item's status observation.
    static func unread(chief: String?, in home: HomeSidebarSource) -> Bool {
        guard let chief else { return false }
        let model = home.model()
        return (model.pinned + model.rows).contains { $0.id.rawValue == chief && $0.unreadCount > 0 }
    }
}
