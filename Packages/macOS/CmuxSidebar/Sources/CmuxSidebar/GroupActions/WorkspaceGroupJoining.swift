public import Foundation
public import CmuxSettings

/// Read/write seam the ``WorkspaceGroupJoinCoordinator`` drives to join an
/// asynchronously-created workspace to a sidebar group, without importing the
/// app-target `TabManager`/`Workspace` god types.
///
/// The coordinator only ever speaks in `UUID` workspace and group identifiers
/// plus the placement value type, so this protocol carries no concrete
/// workspace model. The app target conforms `TabManager` to it at the
/// composition root. Membership of a window's live workspace list is reported
/// through ``currentWorkspaceIds()``; mutation routes through
/// ``addWorkspaceToGroup(workspaceId:groupId:placement:referenceWorkspaceId:)``,
/// which must apply the same group-join semantics the bare sidebar `+` button
/// does.
///
/// The host is held weakly by the coordinator's watchers, so it must be a class.
@MainActor
public protocol WorkspaceGroupJoining: AnyObject {
    /// The ids of the workspaces currently present in the host's window, in
    /// list order. Read each time a change is observed to diff against the
    /// known-ids snapshot taken at install time.
    func currentWorkspaceIds() -> [UUID]

    /// Whether a group with `groupId` still exists in the host's window. A
    /// disappeared group aborts the watch.
    func groupContainsLiveGroup(_ groupId: UUID) -> Bool

    /// Whether a workspace with `workspaceId` is present in the host's window.
    func containsWorkspace(_ workspaceId: UUID) -> Bool

    /// Joins `workspaceId` to `groupId`, honoring the group's configured
    /// placement and anchor reference. Mirrors the bare `+` button's join.
    func addWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?
    )

    /// Observes the host's workspace list and invokes `onChange` after every
    /// mutation (the `@Observable` replacement for the retired
    /// `tabsPublisher` Combine bridge). The returned handle owns the watch's
    /// lifetime; the coordinator cancels it on dispose.
    func observeWorkspaceList(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> WorkspaceGroupJoinObservation
}

/// A cancellable handle for a ``WorkspaceGroupJoining`` workspace-list watch.
/// Holding it keeps the watch armed; ``cancel()`` (or dropping it) stops further
/// change callbacks. Cancellation is idempotent.
@MainActor
public protocol WorkspaceGroupJoinObservation: AnyObject {
    /// Stops the watch. No change handler fires after this returns.
    func cancel()
}
