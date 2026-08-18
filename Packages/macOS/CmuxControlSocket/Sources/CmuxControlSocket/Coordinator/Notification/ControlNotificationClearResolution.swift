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
    /// The clear was accepted. A `nil` workspace/surface pair represents the
    /// legacy unscoped clear; a non-`nil` workspace scopes the clear to that
    /// workspace and an optional surface narrows it further.
    case cleared(workspaceID: UUID?, surfaceID: UUID?)
}
