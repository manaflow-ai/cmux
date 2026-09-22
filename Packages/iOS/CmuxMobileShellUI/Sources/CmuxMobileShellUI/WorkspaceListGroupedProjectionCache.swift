import Foundation
import CmuxMobileShellModel

/// Synchronous input-keyed cache for grouped workspace list projection.
///
/// This is deliberately a non-observable reference type: SwiftUI body updates
/// may read and update it without publishing another invalidation. The cache
/// retains only fields that affect group placement, identity, unread badges,
/// pinning, or the optional recency sort. Row payload is supplied separately.
@MainActor
final class WorkspaceListGroupedProjectionCache {
    private struct WorkspaceKey: Equatable {
        let id: MobileWorkspacePreview.ID
        let name: String
        let isPinned: Bool
        let groupID: MobileWorkspaceGroupPreview.ID?
        let unreadState: MobileWorkspaceUnreadState
        let lastActivityAt: Date?

        init(
            workspace: MobileWorkspacePreview,
            includesActivity: Bool
        ) {
            id = workspace.id
            name = workspace.name
            isPinned = workspace.isPinned
            groupID = workspace.groupID
            unreadState = workspace.unreadState
            lastActivityAt = includesActivity ? workspace.lastActivityAt : nil
        }
    }

    private struct GroupKey: Equatable {
        let id: MobileWorkspaceGroupPreview.ID
        let isEmpty: Bool
        let isPinned: Bool
        let isCollapsed: Bool
        let anchorWorkspaceID: MobileWorkspacePreview.ID?

        init(group: MobileWorkspaceGroupPreview) {
            id = group.id
            isEmpty = group.isEmpty
            isPinned = group.isPinned
            isCollapsed = group.isCollapsed
            anchorWorkspaceID = group.liveAnchorWorkspaceID
        }
    }

    private struct Input: Equatable {
        /// This cache drives list identity and group placement. Row payload is
        /// supplied separately to the table, so relay-only fields such as
        /// terminals, surfaces, and directories must not invalidate it.
        let workspaces: [WorkspaceKey]
        let groups: [GroupKey]
        let appliesRecencySort: Bool
    }

    private var input: Input?
    private var projectedItems: [MobileWorkspaceListItem] = []
    #if DEBUG
    private(set) var projectionBuildCount = 0
    #endif

    func items(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        appliesRecencySort: Bool
    ) -> [MobileWorkspaceListItem] {
        let input = Input(
            workspaces: workspaces.map {
                WorkspaceKey(workspace: $0, includesActivity: appliesRecencySort)
            },
            groups: groups.map(GroupKey.init),
            appliesRecencySort: appliesRecencySort
        )
        if self.input == input {
            return projectedItems
        }

        let projectedItems = appliesRecencySort
            ? MobileWorkspaceRecencyOrder().groupedDisplayItems(workspaces, groups: groups)
            : MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        self.input = input
        self.projectedItems = projectedItems
        #if DEBUG
        projectionBuildCount &+= 1
        #endif
        return projectedItems
    }
}
