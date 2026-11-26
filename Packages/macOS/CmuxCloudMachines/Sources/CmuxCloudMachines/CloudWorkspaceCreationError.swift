/// An explicit empty-fleet result; availability and cancellation remain separate outcomes.
public enum CloudWorkspaceCreationError: Error, Equatable {
    /// No machine in the authenticated fleet is available as a workspace destination.
    case noMachines
}
