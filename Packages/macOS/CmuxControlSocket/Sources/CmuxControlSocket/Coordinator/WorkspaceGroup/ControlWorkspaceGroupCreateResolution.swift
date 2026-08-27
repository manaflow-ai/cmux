public import Foundation

/// The outcome of `workspace.group.create`, preserving the legacy body's
/// app-state failures and the created group it echoes back.
///
/// The coordinator parses `name` / `cwd` / `child_workspace_ids` (resolving each
/// child through the handle registry) and surfaces the param-shape failures
/// (`invalid_params` for a malformed `child_workspace_ids` or unresolved
/// handles) itself. Missing children become an explicit empty list. The target
/// window existence check, all-children-are-anchors guard, and create call
/// depend on live app state, so they happen behind the seam.
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
