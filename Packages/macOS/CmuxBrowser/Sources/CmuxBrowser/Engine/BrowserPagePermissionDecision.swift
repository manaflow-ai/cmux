import Foundation

/// The answer to a ``BrowserPagePermissionRequest``.
public enum BrowserPagePermissionDecision: Equatable, Hashable, Sendable {
    /// Grant the request.
    case grant
    /// Deny the request.
    case deny
    /// Let the engine show its own prompt, where it has one.
    case prompt
}
