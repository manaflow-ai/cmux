/// The outcome of `workspace.group.join`: find a group by name in the
/// workspace's window, or create one, and make the workspace a member.
///
/// The lookup, the create and the add all run in one main-actor turn behind
/// the seam, so concurrent joins with the same name land in one group.
public enum ControlWorkspaceGroupJoinResolution: Sendable, Equatable {
    /// No TabManager resolved (`unavailable`).
    case tabManagerUnavailable
    /// The workspace does not exist in the resolved window (`not_found`).
    case workspaceNotFound
    /// The workspace anchors a different group, so it can't join this one
    /// until that group is ungrouped (`invalid_state`).
    case workspaceIsOtherGroupAnchor
    /// No group had the name and a new one could not be created
    /// (`not_created`).
    case notCreated
    /// The workspace is in the group. `created` is true when the group was
    /// made by this call; `alreadyMember` is true when nothing changed.
    case joined(ControlWorkspaceGroupSnapshot, created: Bool, alreadyMember: Bool)
}
