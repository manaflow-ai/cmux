public import Foundation

/// The outcome of `workspace.group.create`, preserving the legacy body's
/// app-state failures and the created group it echoes back.
///
/// The coordinator parses `name` / `cwd` / `child_workspace_ids` (resolving each
/// child through the handle registry) and surfaces the param-shape failures
/// (`invalid_params` for a malformed `child_workspace_ids` or unresolved
/// handles) itself. The remaining resolution depends on live app state — the
/// fallback selection when children are absent, the existence check against the
/// target window, the all-children-are-anchors eligibility guard, and the create
/// call — so it happens behind the seam and returns one of these cases.
public enum ControlWorkspaceGroupCreateResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// One or more requested children are syntactically valid UUIDs that don't
    /// exist in the target window (legacy `not_found` / "Child workspace not
    /// found in target window: …", `data: {"unknown_workspace_ids": …}`).
    /// Carries the missing workspace id strings, in request order.
    case childWorkspaceNotFound([String])
    /// Every explicitly-listed child is already a group anchor, so only an
    /// anchor-only group could be created (legacy `invalid_state` /
    /// `workspaceGroup.error.allChildrenAreAnchors`, `data:
    /// {"ineligible_workspace_ids": …}`). Carries the ineligible workspace id
    /// strings.
    case allChildrenAreAnchors([String])
    /// The group could not be created (legacy `not_created` / "Group was not
    /// created", `data: nil`).
    case notCreated
    /// The group was created. Carries its snapshot for the `group` payload.
    case created(ControlWorkspaceGroupSnapshot)
}
