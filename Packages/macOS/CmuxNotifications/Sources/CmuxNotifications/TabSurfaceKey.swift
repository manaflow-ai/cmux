public import Foundation

/// Identifies an unread-bearing (workspace, surface) pair inside the notification
/// indexes.
///
/// A workspace can carry unread notifications attributed both to a concrete
/// surface/panel and to the workspace itself (`surfaceId == nil`), so the key
/// holds an optional surface id. Used as a `Set` member by ``NotificationIndexes``.
public struct TabSurfaceKey: Hashable, Sendable {
    /// The id of the workspace (tab) the unread notification belongs to.
    public let tabId: UUID
    /// The id of the surface (or panel) within the workspace, or `nil` for a
    /// workspace-scoped unread.
    public let surfaceId: UUID?

    /// Creates a key for the given workspace/surface pair.
    public init(tabId: UUID, surfaceId: UUID?) {
        self.tabId = tabId
        self.surfaceId = surfaceId
    }
}
