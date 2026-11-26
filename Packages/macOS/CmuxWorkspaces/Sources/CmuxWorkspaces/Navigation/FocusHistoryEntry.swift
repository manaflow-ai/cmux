public import Foundation

/// One focus-history position: a workspace plus the panel that was focused
/// in it (or `nil` when only the workspace-level focus is known).
public struct FocusHistoryEntry: Equatable, Sendable {
    /// The workspace the user focused.
    public let workspaceId: UUID
    /// The focused panel inside the workspace, when known.
    public let panelId: UUID?

    /// Creates an entry for a workspace and optional panel.
    public init(workspaceId: UUID, panelId: UUID?) {
        self.workspaceId = workspaceId
        self.panelId = panelId
    }
}
