public import Foundation

/// Failure reasons surfaced back to the mobile workspace-list UI for Mac-backed
/// workspace and workspace-group mutations.
public enum MobileWorkspaceMutationFailure: Error, Equatable, Sendable {
    /// The target Mac was not connected when the action was attempted.
    case notConnected(hostDisplayName: String?)
    /// The target Mac did not answer before the request timeout expired.
    case requestTimedOut(hostDisplayName: String?)
    /// The request failed authorization against the target Mac.
    case authorizationFailed(hostDisplayName: String?)
    /// Another local workspace mutation is already in flight with a different target.
    case busy(hostDisplayName: String?)
    /// The target Mac rejected the requested mutation.
    case rejected(hostDisplayName: String?)
    /// The current host does not support the requested mutation.
    case unsupported(hostDisplayName: String?)
}
