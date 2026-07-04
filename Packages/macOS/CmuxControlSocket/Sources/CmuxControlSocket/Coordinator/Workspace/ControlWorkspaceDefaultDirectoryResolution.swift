public import Foundation

/// The outcome of `workspace.get_cwd` and `workspace.set_cwd`.
public enum ControlWorkspaceDefaultDirectoryResolution: Sendable, Equatable {
    /// No workspace context resolved (`unavailable` / "Workspace unavailable").
    case tabManagerUnavailable
    /// A TabManager resolved but had no selected workspace.
    case noWorkspaceSelected
    /// The requested workspace was not found.
    case notFound
    /// The read or mutation succeeded.
    case resolved(windowID: UUID?, workspaceID: UUID, cwd: String?)
}
