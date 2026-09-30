public import Foundation

/// The result of a non-interactive window close request.
public enum ControlWindowCloseResolution: Sendable, Equatable {
    case resolved
    case confirmationRequired(workspaceIDs: [UUID])
    case notFound
}
