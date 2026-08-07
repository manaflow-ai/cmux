import Foundation

/// Immutable identity for one process-wide workspace drag.
struct SidebarWorkspaceDragSession: Equatable, Sendable {
    let id: UUID
    let workspaceId: UUID

    init(id: UUID = UUID(), workspaceId: UUID) {
        self.id = id
        self.workspaceId = workspaceId
    }
}
