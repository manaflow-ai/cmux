public import Foundation

/// A desired portal-rendering transition for a workspace.
public struct WorkspacePortalRenderingChange: Equatable {
    /// The workspace whose portal-rendering state should be updated.
    public let workspaceId: UUID
    /// Whether portal rendering should be enabled for the workspace.
    public let isEnabled: Bool

    /// Creates a portal-rendering state change.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace whose state should change.
    ///   - isEnabled: Whether portal rendering should be enabled.
    public init(workspaceId: UUID, isEnabled: Bool) {
        self.workspaceId = workspaceId
        self.isEnabled = isEnabled
    }
}
