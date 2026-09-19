import Foundation

/// Selection state captured by a window before starting a New Workspace action.
public enum CloudWorkspaceMachineSelection: Equatable, Sendable {
    /// No Machines row is selected.
    case none
    /// This Mac is selected.
    case local
    /// A Cloud machine row or descendant is selected.
    case cloud(String)
    /// A pending machine row is selected and cannot accept a workspace yet.
    case pending
}
