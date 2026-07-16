import Foundation

/// Shared context-menu facts derived from a target workspace selection.
///
/// The sidebar computes the selected-set aggregate once above `LazyVStack`.
/// Selected rows reuse this immutable value instead of repeating remote,
/// grouping, unread, and notification aggregation during row realization.
struct SidebarWorkspaceContextMenuTargetAggregate: Equatable {
    let targetWorkspaceIds: [UUID]
    let remoteTargetWorkspaceIds: [UUID]
    let allRemoteTargetsConnecting: Bool
    let allRemoteTargetsDisconnected: Bool
    let eligibleGroupTargetIds: [UUID]
    let allEligibleTargetsGroupId: UUID?
    let hasGroupedEligibleTarget: Bool
    let canMarkRead: Bool
    let canMarkUnread: Bool

    init(
        targetWorkspaceIds: [UUID],
        modelSnapshotsById: [UUID: SidebarWorkspaceRowModelSnapshot],
        unreadSummariesByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary],
        anchorWorkspaceIds: Set<UUID>
    ) {
        self.targetWorkspaceIds = targetWorkspaceIds
        remoteTargetWorkspaceIds = targetWorkspaceIds.filter {
            modelSnapshotsById[$0]?.isRemoteContextMenuEligible == true
        }
        allRemoteTargetsConnecting = !remoteTargetWorkspaceIds.isEmpty
            && remoteTargetWorkspaceIds.allSatisfy {
                guard let state = modelSnapshotsById[$0]?.remoteConnectionState else { return false }
                return state == .connecting || state == .reconnecting
            }
        allRemoteTargetsDisconnected = !remoteTargetWorkspaceIds.isEmpty
            && remoteTargetWorkspaceIds.allSatisfy {
                modelSnapshotsById[$0]?.remoteConnectionState == .disconnected
            }
        eligibleGroupTargetIds = targetWorkspaceIds.filter {
            !anchorWorkspaceIds.contains($0) && modelSnapshotsById[$0] != nil
        }
        let eligibleGroupIds = eligibleGroupTargetIds.map { modelSnapshotsById[$0]?.groupId }
        allEligibleTargetsGroupId = Self.commonGroupId(eligibleGroupIds)
        hasGroupedEligibleTarget = eligibleGroupTargetIds.contains {
            modelSnapshotsById[$0]?.groupId != nil
        }
        canMarkRead = targetWorkspaceIds.contains {
            (unreadSummariesByWorkspaceId[$0]?.unreadCount ?? 0) > 0
        }
        canMarkUnread = targetWorkspaceIds.contains {
            (unreadSummariesByWorkspaceId[$0]?.unreadCount ?? 0) == 0
        }
    }

    private static func commonGroupId(_ groupIds: [UUID?]) -> UUID? {
        guard let first = groupIds.first,
              groupIds.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }
}
