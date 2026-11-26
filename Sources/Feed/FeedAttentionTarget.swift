import Foundation

/// Identifies the stable owner of one Feed decision-attention overlay.
enum FeedAttentionTarget: Hashable, Sendable {
    /// Attention owned by a panel that can move between workspace and Dock containers.
    case panel(id: UUID, statusKey: String)
    /// Attention owned by a workspace when no panel identity is available.
    case workspace(id: UUID, statusKey: String)
    /// Attention owned by a Dock when no panel identity is available.
    case dock(id: UUID, statusKey: String)

    /// The Feed-owned lifecycle and sidebar-status slot.
    var statusKey: String {
        switch self {
        case .panel(_, let statusKey), .workspace(_, let statusKey), .dock(_, let statusKey):
            statusKey
        }
    }

    /// The stable panel identity, when a panel owns the overlay.
    var panelId: UUID? {
        guard case .panel(let id, _) = self else { return nil }
        return id
    }
}
