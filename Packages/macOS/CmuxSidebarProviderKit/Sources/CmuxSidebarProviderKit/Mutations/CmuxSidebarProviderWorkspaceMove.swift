import Foundation

/// Drag-and-drop move request for a workspace row.
public struct CmuxSidebarProviderWorkspaceMove: Codable, Equatable, Sendable {
    /// Workspace being moved.
    public var workspaceId: UUID
    /// Source section id, if known.
    public var sourceSectionId: String?
    /// Destination section id.
    public var targetSectionId: String
    /// Destination row index inside the target section.
    public var targetIndex: Int

    /// Creates a workspace move request.
    public init(
        workspaceId: UUID,
        sourceSectionId: String?,
        targetSectionId: String,
        targetIndex: Int
    ) {
        self.workspaceId = workspaceId
        self.sourceSectionId = sourceSectionId
        self.targetSectionId = targetSectionId
        self.targetIndex = targetIndex
    }
}
