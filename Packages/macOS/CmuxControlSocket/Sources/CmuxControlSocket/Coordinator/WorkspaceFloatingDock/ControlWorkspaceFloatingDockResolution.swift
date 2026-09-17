public import Foundation

/// App-side resolution of a workspace floating Dock operation.
public enum ControlWorkspaceFloatingDockResolution: Sendable, Equatable {
    case tabManagerUnavailable
    case workspaceNotFound
    case floatingDockNotFound
    case paneNotFound
    case surfaceNotFound
    case invalidSurfaceKind(String)
    case invalidDirection(String)
    case operationFailed(String)
    case resolved(JSONValue)
}
