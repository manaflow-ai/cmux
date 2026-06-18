public import Foundation

/// The minimal per-workspace ordering facts a reorder plan needs: identity
/// and pinned state, captured in current tab order.
public struct WorkspaceOrderSnapshot: Equatable, Sendable {
    /// The workspace's identity.
    public let id: UUID
    /// Whether the workspace is pinned (pinned rows stay ahead of unpinned).
    public let isPinned: Bool

    /// Creates a snapshot entry.
    public init(id: UUID, isPinned: Bool) {
        self.id = id
        self.isPinned = isPinned
    }
}
