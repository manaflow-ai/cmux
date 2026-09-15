import Foundation

/// Errors that keep a captured Cloud workspace request fail-closed.
public enum CloudWorkspaceCoordinatorError: Error, Equatable, Sendable {
    /// The selected machine was absent from the authoritative fleet response.
    case machineUnavailable(String)
    /// The originating window was closed before the local projection completed.
    case targetWindowUnavailable(UUID)
}
