import Foundation

/// Errors that keep an explicit Cloud workspace request fail-closed.
public enum CloudWorkspaceCoordinatorError: Error, Equatable, Sendable {
    /// The selected machine was absent from the authoritative fleet response.
    case machineUnavailable(String)
    /// The originating window closed before the local projection completed.
    case targetWindowUnavailable(UUID)
}
