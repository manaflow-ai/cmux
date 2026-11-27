public import Foundation

/// The outcome of `workspace.equalize_splits`, preserving the legacy body's
/// failures and the success echo.
public enum ControlWorkspaceEqualizeResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// No workspace resolved from the routing selectors (legacy `not_found` /
    /// "Workspace not found").
    case notFound
    /// The splits were equalized. Carries the resolved workspace id and whether
    /// the tree fully equalized.
    case resolved(workspaceID: UUID, equalized: Bool)
}
