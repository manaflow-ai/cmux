public import Foundation

/// App-side resolution of a workspace floating Dock operation.
public enum ControlWorkspaceFloatingDockResolution: Sendable, Equatable {
    case tabManagerUnavailable
    case workspaceNotFound
    case floatingDockNotFound
    case paneNotFound
    case surfaceNotFound
    case invalidInitialContent(String)
    case invalidSurfaceKind(String)
    case invalidDirection(String)
    case invalidColor(String)
    case operationFailed(String)
    /// The close was accepted and is waiting for note persistence. Callers can
    /// poll `workspace.float.list`; the payload identifies the requested Dock.
    case pending(JSONValue)
    case resolved(JSONValue)
}
