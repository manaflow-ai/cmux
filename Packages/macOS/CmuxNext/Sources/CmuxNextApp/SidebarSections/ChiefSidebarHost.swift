import CmuxHomeCore
import CmuxNextAgentLanes
import CmuxNextHomeEngine

extension ChiefSidebar.Host {
    /// The App's Chief for the sidebar item: Home's Chief conversation, the Chief host's tabs and
    /// workspaces, and whether Home shows the conversation unread. `conversation`: which one is the Chief's (a test names it).
    static func app(_ services: AppServices, conversation: @escaping () -> String? = { nil }) -> Self {
        let chief = { conversation() ?? TopHomePageView.chief(services.home) }
        return .init(conversation: chief, chiefHost: { services.agentTabs.chiefHost },
                     tab: { services.agentTabs.tab(showing: $0, host: $1) }, reveal: { services.revealTab($0) },
                     openWorkspace: { try AgentSessionWorkspace.open(session: $0, name: nil, cwd: nil, host: $1, services: services) },
                     unread: { unread(chief: chief(), in: services.home.groupMuting) })
    }

    /// Whether Home's list dots the Chief's conversation `chief`: one of Home's unread conversations, as `home`
    /// (the source behind ``HomeService/unreadConversations``) maps them: unread messages or Mark as Unread,
    /// never a muted one. Read in the item's status observation, so a message, a read or a mark re-yields.
    static func unread(chief: String?, in home: HomeSidebarSource) -> Bool {
        guard let chief else { return false }
        return home.unreadConversations.contains(ConversationID(chief))
    }
}
