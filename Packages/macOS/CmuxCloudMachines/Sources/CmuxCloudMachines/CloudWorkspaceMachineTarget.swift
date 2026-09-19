import Foundation

/// Destination resolved for a New Workspace action.
public enum CloudWorkspaceMachineTarget: Equatable, Sendable {
    /// Create on this Mac.
    case local
    /// Create on this Cloud machine id.
    case cloud(String)
    /// The selected Cloud row cannot accept creation.
    case unavailable
}
