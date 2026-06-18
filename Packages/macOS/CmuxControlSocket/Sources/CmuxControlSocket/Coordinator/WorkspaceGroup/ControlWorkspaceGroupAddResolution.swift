public import Foundation

/// The outcome of `workspace.group.add`, preserving the legacy body's two
/// distinct failures.
///
/// `addWorkspaceToGroup` silently no-ops for a workspace that is the anchor of
/// another group, so the legacy body confirmed membership actually changed and
/// distinguished that case (an `invalid_state` with a localized message) from
/// the generic `not_found`. The coordinator builds the error envelopes and the
/// `{group_id, workspace_id}` data; the seam signals which failure occurred.
public enum ControlWorkspaceGroupAddResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The workspace was added to the group.
    case added
    /// The group or workspace was not found, or the add no-op'd for an
    /// unspecified reason (legacy `not_found` / "Group or workspace not found").
    case notFound
    /// The workspace is the anchor of another group, so it can't join this one
    /// until ungrouped (legacy `invalid_state` /
    /// `workspaceGroup.error.workspaceIsOtherGroupAnchor`).
    case workspaceIsOtherGroupAnchor
}
