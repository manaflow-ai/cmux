public import Foundation

/// The exact surface unread state published for one rendered owner.
public struct SidebarSurfaceUnreadProjection: Equatable, Sendable {
    /// The workspace or window identifier that owns the surfaces.
    public let ownerId: UUID
    /// Exact surface identifiers with effective unread state.
    public let unreadSurfaceIds: Set<UUID>
    /// The focused surface whose read indicator remains visible, when present.
    public let focusedReadSurfaceId: UUID?

    /// Creates one owner-scoped surface projection.
    ///
    /// - Parameters:
    ///   - ownerId: The workspace or window identifier that owns the surfaces.
    ///   - unreadSurfaceIds: Exact surface identifiers with effective unread state.
    ///   - focusedReadSurfaceId: The focused surface whose read indicator remains visible.
    public init(
        ownerId: UUID,
        unreadSurfaceIds: Set<UUID> = [],
        focusedReadSurfaceId: UUID? = nil
    ) {
        self.ownerId = ownerId
        self.unreadSurfaceIds = unreadSurfaceIds
        self.focusedReadSurfaceId = focusedReadSurfaceId
    }

    /// Returns whether the exact surface is unread.
    ///
    /// - Parameter surfaceId: The exact surface identifier to query.
    /// - Returns: `true` when the surface has effective unread state.
    public func hasUnread(surfaceId: UUID) -> Bool {
        unreadSurfaceIds.contains(surfaceId)
    }

    /// Returns whether the exact surface should render an unread indicator.
    ///
    /// - Parameter surfaceId: The exact surface identifier to query.
    /// - Returns: `true` when unread or retained as the focused read indicator.
    public func hasVisibleIndicator(surfaceId: UUID) -> Bool {
        hasUnread(surfaceId: surfaceId) || focusedReadSurfaceId == surfaceId
    }
}
