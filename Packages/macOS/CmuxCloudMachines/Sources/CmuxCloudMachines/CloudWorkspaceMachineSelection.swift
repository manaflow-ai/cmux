import Foundation

/// Selection state captured before a New Workspace action starts.
public enum CloudWorkspaceMachineSelection: Equatable, Sendable {
    /// No Machines row is selected.
    case none
    /// This Mac is selected.
    case local
    /// A Cloud machine row or descendant is selected.
    case cloud(String)
    /// A pending machine row cannot accept workspace creation.
    case pending
}
