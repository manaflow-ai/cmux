public import Foundation

/// The outcome of a scoped notification clear.
public enum ControlNotificationClearResolution: Sendable, Equatable {
    /// No TabManager was available to resolve the requested scope.
    case tabManagerUnavailable
    /// The requested workspace was not found. The associated id is the one the
    /// caller supplied, when one was available.
    case workspaceNotFound(workspaceID: UUID?)
    /// The requested surface was not found in the resolved workspace.
    case surfaceNotFound(UUID)
    /// The clear was accepted for a workspace, optionally narrowed to a surface.
    /// A surface identifier can never be returned without its owning workspace.
    case cleared(workspaceID: UUID, surfaceID: UUID?)
}
