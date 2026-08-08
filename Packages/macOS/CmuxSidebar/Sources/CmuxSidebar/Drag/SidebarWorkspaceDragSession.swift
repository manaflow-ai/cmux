public import Foundation

/// Immutable identity for one process-wide workspace drag.
public struct SidebarWorkspaceDragSession: Equatable, Sendable {
    /// Generation token that prevents stale completion from ending a newer drag.
    public let id: UUID

    /// Workspace represented by the drag.
    public let workspaceId: UUID

    /// Creates a tokenized workspace drag session.
    /// - Parameters:
    ///   - id: Generation token for this drag. Defaults to a fresh UUID.
    ///   - workspaceId: Workspace represented by the drag.
    public init(id: UUID = UUID(), workspaceId: UUID) {
        self.id = id
        self.workspaceId = workspaceId
    }
}
