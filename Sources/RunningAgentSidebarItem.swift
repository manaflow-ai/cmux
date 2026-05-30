import Foundation

struct RunningAgentSidebarItem: Equatable, Identifiable {
    let id: String
    let workspaceId: UUID
    let tabId: UUID
    let surfaceId: UUID
    let workspaceName: String
    let workspaceIndex: Int
    let agentKey: String
    let agentName: String
    let lifecycleState: AgentHibernationLifecycleState
    let statusText: String
    let statusIcon: String?
    let statusColor: String?
    let latestNotificationText: String?
}
