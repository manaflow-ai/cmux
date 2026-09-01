import Foundation

/// Immutable context-menu inputs for one workspace row.
///
/// The live workspace graph is resolved above the sidebar's `LazyVStack` and
/// reduced to this value. Menu actions are supplied separately as closures, so
/// opening a menu cannot subscribe a lazy row to `TabManager`, `Workspace`, or
/// the notification store.
struct SidebarWorkspaceContextMenuSnapshot: Equatable {
    let targetWorkspaceIds: [UUID]
    let remoteTargetWorkspaceIds: [UUID]
    let allRemoteTargetsConnecting: Bool
    let allRemoteTargetsDisconnected: Bool
    let pinState: WorkspaceActionDispatcher.PinState?
    /// Aggregate mute state of the targets: true only when every target
    /// workspace is muted. Drives the Mute/Unmute label + action.
    let allTargetsNotificationsMuted: Bool
    let groupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let canCreateEmptyGroup: Bool
    let eligibleGroupTargetIds: [UUID]
    let allEligibleTargetsGroupId: UUID?
    let hasGroupedEligibleTarget: Bool
    let todoStatusLanes: [WorkspaceTodoStatusLane]
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotification: Bool
    let notifications: [TerminalNotification]
}
