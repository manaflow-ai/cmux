public import Foundation

/// The outcome of `workspace.group.new_workspace`, preserving the legacy body's
/// failures and the created workspace it echoes back.
///
/// Placement resolution (explicit param, then the group's per-cwd config, then
/// the global default) and the create call depend on live app state, so they sit
/// behind the seam. The bad-placement `invalid_params` is surfaced here too so
/// the seam owns the single `WorkspaceGroupNewPlacement` parse.
public enum ControlWorkspaceGroupNewWorkspaceResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The `placement` param was present but not one of the accepted values
    /// (legacy `invalid_params` / "placement must be one of: afterCurrent, top,
    /// end", `data: {"placement": <raw>}`). Carries the raw placement string.
    case invalidPlacement(String)
    /// The group was not found (legacy `not_found` / "Group not found", `data:
    /// {"group_id": …}`).
    case notFound
    /// The workspace was created in the group. Carries its id (the coordinator
    /// mints the workspace ref).
    case created(workspaceID: UUID)
}
