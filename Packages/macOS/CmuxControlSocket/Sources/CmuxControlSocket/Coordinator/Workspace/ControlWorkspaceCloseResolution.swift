public import Foundation

/// The outcome of `workspace.close`, preserving the legacy body's failures and
/// the resolved window the success/protected branches echo back. The
/// coordinator has already validated `workspace_id` shape.
public enum ControlWorkspaceCloseResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The workspace exists but is pinned and cannot be closed (legacy
    /// `protected`). Carries the owning window id (may be absent); the localized
    /// message is supplied via ``ControlWorkspaceStrings``.
    case protected(windowID: UUID?)
    /// The workspace was not in the resolved TabManager (legacy `not_found` /
    /// "Workspace not found"). The legacy failure payload carries only the
    /// workspace identity.
    case notFound
    /// The workspace resolved and was eligible to close, but local teardown did
    /// not complete. Carries the owning window id (may be absent).
    case closeFailed(windowID: UUID?)
    /// The workspace was closed. Carries the owning window id (may be absent).
    case resolved(windowID: UUID?)
}
