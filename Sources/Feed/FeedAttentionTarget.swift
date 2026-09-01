import Foundation

/// Exact sidebar evidence owned by one Feed attention overlay.
///
/// The opaque token prevents a late conclusion from a dead process generation
/// from clearing a newer decision after PID replacement or a panel move.
nonisolated struct FeedAttentionTarget: Hashable, Sendable {
    let workspaceId: UUID
    /// The panel that owns the overlay, or `nil` for a workspace-scoped Feed
    /// overlay whose event did not include a surface identity.
    let panelId: UUID?
    let statusKey: String
    let token: AgentFeedAttentionToken
}
