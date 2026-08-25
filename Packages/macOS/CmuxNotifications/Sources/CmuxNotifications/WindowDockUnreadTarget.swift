public import Foundation

/// A surface-scoped unread target in one per-window Dock.
///
/// Window Dock owner identifiers are window IDs, not workspace IDs. Keeping
/// this value distinct prevents notification navigation from feeding a Dock
/// owner into workspace-only routing.
public struct WindowDockUnreadTarget: Hashable, Sendable {
    /// The main-window identifier that owns the Dock.
    public let windowId: UUID

    /// The exact Dock surface carrying unread attention.
    public let surfaceId: UUID

    /// Creates a per-window Dock unread target.
    public init(windowId: UUID, surfaceId: UUID) {
        self.windowId = windowId
        self.surfaceId = surfaceId
    }
}
