public import Foundation

/// The outcome of `surface.refresh`, preserving the legacy body's failure and the
/// refreshed count.
///
/// The coordinator signals `unavailable`; the app resolves the workspace,
/// force-refreshes every terminal surface, and returns the count and identity.
public enum ControlSurfaceRefreshResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// The terminals were refreshed. Carries the echoed identity and the count.
    case refreshed(windowID: UUID?, workspaceID: UUID, refreshedCount: Int)
}
