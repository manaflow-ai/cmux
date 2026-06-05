import Foundation

struct AttentionTarget: Sendable {
    let workspaceId: UUID
    let surfaceId: UUID?
    let statusKey: String
    let previousStatusEntry: SidebarStatusEntry?
    let previousLifecycle: AgentHibernationLifecycleState?
}
