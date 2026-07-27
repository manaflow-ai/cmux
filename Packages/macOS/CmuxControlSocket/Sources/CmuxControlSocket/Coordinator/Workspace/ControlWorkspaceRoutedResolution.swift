public import Foundation

/// A routed workspace mutation outcome shared by `workspace.select` and
/// `workspace.rename`: resolve a TabManager, act on a workspace by id, echo the
/// owning window on success. Both legacy bodies share this exact failure
/// triple, and both `not_found` payloads carry only the workspace identity the
/// coordinator already holds.
public enum ControlWorkspaceRoutedResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The workspace was not in the resolved TabManager (legacy `not_found` /
    /// "Workspace not found").
    case notFound
    /// The mutation succeeded. Carries the owning window id (may be absent).
    case resolved(windowID: UUID?)
}
