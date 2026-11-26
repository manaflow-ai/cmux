import Foundation

/// An ordered browser-stack sidebar row, identified by its workspace and the
/// section it currently belongs to. Used by
/// `ExtensionSidebarBrowserStackDropPlanner` to compute cross-section drag moves.
public struct ExtensionSidebarBrowserStackDropRow: Equatable {
    public let workspaceId: UUID
    public let sectionId: String

    public init(workspaceId: UUID, sectionId: String) {
        self.workspaceId = workspaceId
        self.sectionId = sectionId
    }
}
