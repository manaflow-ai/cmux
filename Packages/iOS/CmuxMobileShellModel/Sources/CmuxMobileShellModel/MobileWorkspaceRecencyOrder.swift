internal import Foundation

/// Flat, cross-computer presentation order for
/// ``MobileWorkspaceSortMode/recentActivity``.
///
/// This runs at the presentation layer, not in the aggregation: time
/// interleaving across Macs cannot keep one Mac's group members contiguous, so
/// the aggregated `workspaces` array keeps its natural order (group sections,
/// anchors, and move RPCs depend on it) and the list view applies this order to
/// its flat path only.
public struct MobileWorkspaceRecencyOrder: Sendable {
    /// Create a recency-order helper.
    public init() {}

    /// Pinned rows first (the flat list's standing rule), then most recent
    /// `lastActivityAt` first. Rows without a timestamp sort last, and every
    /// tie keeps the incoming order so the list cannot shuffle between
    /// refreshes of equal payloads.
    public func displayOrder(_ workspaces: [MobileWorkspacePreview]) -> [MobileWorkspacePreview] {
        workspaces.enumerated().sorted { lhs, rhs in
            if lhs.element.isPinned != rhs.element.isPinned {
                return lhs.element.isPinned
            }
            switch (lhs.element.lastActivityAt, rhs.element.lastActivityAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
