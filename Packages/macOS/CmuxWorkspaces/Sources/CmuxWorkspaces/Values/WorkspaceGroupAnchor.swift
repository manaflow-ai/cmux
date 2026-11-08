public import Foundation

/// Identifies what currently owns a workspace group's header row.
public enum WorkspaceGroupAnchor: Equatable, Hashable, Sendable {
    /// A live workspace is rendered as the group header and receives focus.
    case workspace(UUID)
    /// The group has no live workspaces; the associated id keeps its header
    /// identity stable for ordering, rendering, and session restore.
    case empty(UUID)

    /// Stable row identity used by sidebar and persistence projections.
    public var identity: UUID {
        switch self {
        case .workspace(let id), .empty(let id):
            return id
        }
    }

    /// The live workspace id, when the group currently has one.
    public var workspaceId: UUID? {
        switch self {
        case .workspace(let id): id
        case .empty: nil
        }
    }

    /// Whether this anchor represents an empty group.
    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}
