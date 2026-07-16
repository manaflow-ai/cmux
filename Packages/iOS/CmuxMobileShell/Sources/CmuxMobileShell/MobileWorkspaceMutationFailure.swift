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
    /// The target is protected by a host policy, such as a pinned boundary.
    case protected(hostDisplayName: String?)
    /// The target changed and now requires an explicit destructive confirmation.
    case confirmationRequired(hostDisplayName: String?)
    /// The current host does not support the requested mutation.
    case unsupported(hostDisplayName: String?)
    /// The Mac acknowledged the mutation, but iOS could not reload its result.
    case appliedNeedsRefresh(hostDisplayName: String?)
    /// The request may have reached the Mac, and iOS could not reconcile the result.
    case resultUnknownNeedsRefresh(hostDisplayName: String?)
    /// The request result is unknown, but iOS loaded the Mac's latest authoritative state.
    case resultUnknownRefreshed(hostDisplayName: String?)
    /// The Mac rejected the mutation because iOS acted on stale state, and the
    /// authoritative refresh needed before another mutation also failed.
    case staleStateNeedsRefresh(hostDisplayName: String?)
}
