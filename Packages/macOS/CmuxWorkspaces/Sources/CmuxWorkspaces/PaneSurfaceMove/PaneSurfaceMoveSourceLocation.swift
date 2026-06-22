public import Foundation

/// The window + workspace that currently own a surface being moved, as resolved
/// by ``PaneSurfaceMoveHosting`` for ``PaneSurfaceMoveCoordinator``.
///
/// The legacy `AppDelegate.locateSurface(surfaceId:)` returned a
/// `(windowId, workspaceId, tabManager)` tuple; the live `TabManager` stays
/// app-side, so the coordinator only receives the two identifiers it needs to
/// route the move (decide same-workspace vs cross-workspace, and label the focus
/// reassert). `Sendable, Equatable` value type naming no app type.
public struct PaneSurfaceMoveSourceLocation: Sendable, Equatable {
    /// The window that currently owns the surface.
    public let windowId: UUID
    /// The workspace that currently owns the surface.
    public let workspaceId: UUID

    /// Creates a source location from its window and workspace identifiers.
    public init(windowId: UUID, workspaceId: UUID) {
        self.windowId = windowId
        self.workspaceId = workspaceId
    }
}
