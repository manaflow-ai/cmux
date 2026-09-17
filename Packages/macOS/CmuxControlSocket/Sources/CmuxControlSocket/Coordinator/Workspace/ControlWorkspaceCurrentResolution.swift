public import Foundation

/// The outcome of `workspace.current`, preserving the legacy body's two distinct
/// failures and the resolved window/workspace the success echoes back.
public enum ControlWorkspaceCurrentResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// A TabManager resolved but had no selected workspace (legacy `not_found` /
    /// "No workspace selected").
    case noWorkspaceSelected
    /// The selected workspace id resolved. Carries the owning window id (may be
    /// absent), the selected workspace's id, its index within the list (if
    /// resolvable), and its summary — `nil` when `selectedTabId` points at a
    /// workspace missing from `tabs` (the legacy body still answered `.ok` with
    /// `"workspace": null` in that state).
    case resolved(
        windowID: UUID?,
        workspaceID: UUID,
        index: Int?,
        summary: ControlWorkspaceSummary?
    )
}
