import CmuxWorkspaces
import Foundation

/// Stable value identity for one drawable item in the workspace sidebar.
///
/// Keep live `Workspace` / `WorkspaceGroup` references out of this value. A
/// `LazyVStack` copies and diffs its `ForEach` data while placing rows; carrying
/// the models through that path made scrolling copy the live sidebar graph and
/// blurred the ownership boundary between layout data and observed state.
/// Models are resolved from the parent-owned render context only when SwiftUI
/// asks to realize a row.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(groupId: UUID, anchorWorkspaceId: UUID)
    case workspace(workspaceId: UUID)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId, _):
            return .group(groupId)
        case .workspace(let workspaceId):
            return .workspace(workspaceId)
        }
    }

    var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(_, let anchorWorkspaceId):
            return anchorWorkspaceId
        case .workspace(let workspaceId):
            return workspaceId
        }
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        orderedGroups: [WorkspaceGroup]? = nil,
        effectiveMembership: [UUID: UUID?]? = nil
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty || !groupsById.isEmpty else { return [] }
        let effectiveMembershipByWorkspaceId = effectiveMembership
            ?? effectiveGroupIdByWorkspaceId(tabs: tabs, groupsById: groupsById)
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count)
        var lastEmittedGroupId: UUID? = nil
        var emittedHeaders: Set<UUID> = []
        var collapsedByGroupId: [UUID: Bool] = [:]
        var skipChildrenUntilNextGroup = false
        for tab in tabs {
            // Render and row configuration must agree on whether this tab is
            // actually grouped. A stale group id (or a group whose live anchor
            // disappeared) is a root row, even if it sits between members of a
            // valid group in the persisted tab order.
            let groupId = effectiveMembershipByWorkspaceId[tab.id] ?? nil
            if groupId != lastEmittedGroupId {
                lastEmittedGroupId = groupId
                skipChildrenUntilNextGroup = false
                if let groupId, let group = groupsById[groupId] {
                    if !emittedHeaders.contains(groupId) {
                        items.append(.groupHeader(
                            groupId: group.id,
                            anchorWorkspaceId: group.anchorWorkspaceId
                        ))
                        emittedHeaders.insert(groupId)
                        collapsedByGroupId[groupId] = group.isCollapsed
                    }
                    // If legacy reorder paths ever leave a group's members in
                    // two runs, keep honoring the same collapse decision.
                    skipChildrenUntilNextGroup = collapsedByGroupId[groupId] ?? false
                }
            }
            // Anchor workspaces are represented exclusively by the group header.
            if let groupId, let group = groupsById[groupId], group.liveAnchorWorkspaceId == tab.id {
                continue
            }
            if groupId == nil || !skipChildrenUntilNextGroup {
                items.append(.workspace(workspaceId: tab.id))
            }
        }

        // Empty pinned groups have no tab row from which a header can be
        // discovered. Emit them as first-class header-only rows, keeping the
        // model's group order within each pin tier. Empty unpinned groups are
        // placed after live rows; they are uncommon (normal close paths remove
        // them) but remain renderable until an explicit mutation removes them.
        let ordered = orderedGroups
            ?? groupsById.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let memberGroupIds = Set(effectiveMembershipByWorkspaceId.values.compactMap { $0 })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        // Only durable empty groups belong in the header-only projection. A
        // nonempty group whose anchor went stale is intentionally absent from
        // the render tree; treating it as empty would create a ghost header.
        let emptyGroups = ordered.filter {
            $0.isEmpty && !memberGroupIds.contains($0.id)
        }
        guard !emptyGroups.isEmpty else { return items }

        var emptyBeforeGroup: [UUID: [WorkspaceGroup]] = [:]
        var trailingPinned: [WorkspaceGroup] = []
        var trailingUnpinned: [WorkspaceGroup] = []
        var nextLivePinnedGroup: WorkspaceGroup?
        var nextLiveUnpinnedGroup: WorkspaceGroup?
        var nextLiveSameTierByIndex: [WorkspaceGroup?] = Array(
            repeating: nil,
            count: ordered.count
        )
        for index in ordered.indices.reversed() {
            let group = ordered[index]
            nextLiveSameTierByIndex[index] = group.isPinned
                ? nextLivePinnedGroup
                : nextLiveUnpinnedGroup
            guard memberGroupIds.contains(group.id) else { continue }
            if group.isPinned {
                nextLivePinnedGroup = group
            } else {
                nextLiveUnpinnedGroup = group
            }
        }
        for (index, group) in ordered.enumerated() where !memberGroupIds.contains(group.id) {
            // Preserve the group's authoritative slot within its pin tier.
            // Crossing tiers would violate the sidebar's pinned-first
            // invariant, so only a later live group in the same tier is a
            // valid insertion anchor; otherwise defer to that tier boundary.
            let nextLiveSameTierGroup = nextLiveSameTierByIndex[index]
            if let nextLiveSameTierGroup {
                emptyBeforeGroup[nextLiveSameTierGroup.id, default: []].append(group)
            } else if group.isPinned {
                trailingPinned.append(group)
            } else {
                trailingUnpinned.append(group)
            }
        }

        var rendered: [SidebarWorkspaceRenderItem] = []
        rendered.reserveCapacity(items.count + emptyGroups.count)
        for item in items {
            if case .groupHeader(let groupId, _) = item,
               let preceding = emptyBeforeGroup[groupId] {
                rendered.append(contentsOf: preceding.map {
                    .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
                })
            }
            rendered.append(item)
        }
        if !trailingPinned.isEmpty {
            let firstUnpinnedIndex = rendered.firstIndex { item in
                switch item {
                case .groupHeader(let groupId, _):
                    return groupsById[groupId]?.isPinned == false
                case .workspace(let workspaceId):
                    guard let workspace = tabsById[workspaceId] else {
                        return false
                    }
                    if let groupId = effectiveMembershipByWorkspaceId[workspace.id] ?? nil,
                       let group = groupsById[groupId] {
                        return !group.isPinned
                    }
                    return !workspace.isPinned
                }
            } ?? rendered.count
            rendered.insert(contentsOf: trailingPinned.map {
                .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
            }, at: firstUnpinnedIndex)
        }
        rendered.append(contentsOf: trailingUnpinned.map {
            .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
        })
        return rendered
    }

    /// Workspace ids represented by ordinary rows, in their rendered order.
    ///
    /// Group headers represent their anchor workspace for interaction, but are
    /// containers rather than numbered workspace rows.
    static func numberedWorkspaceIds(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID] {
        renderItems.compactMap { item in
            guard case .workspace(let workspaceId) = item else { return nil }
            return workspaceId
        }
    }

    static func numberedWorkspaceIndexById(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(renderItems.count)
        for item in renderItems {
            guard case .workspace(let workspaceId) = item else { continue }
            result[workspaceId] = result.count
        }
        return result
    }

    static func numberedWorkspaceIds(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID] {
        numberedWorkspaceIds(from: renderItems(tabs: tabs, groupsById: groupsById))
    }

    static func memberWorkspaceIdsByGroupId(tabs: [Workspace]) -> [UUID: [UUID]] {
        memberWorkspaceIdsByGroupId(tabs: tabs, groupsById: nil)
    }

    /// Returns the group membership that is safe for sidebar rendering.
    ///
    /// A workspace may carry a stale group id after a restore or an
    /// in-flight anchor promotion. Only groups with a live anchor (or an
    /// explicitly empty durable anchor) are renderable; all other references
    /// become root-level rows. A live anchor also wins when its workspace's
    /// copied `groupId` is temporarily nil, keeping the header and member rows
    /// on one authoritative group run.
    static func effectiveGroupIdByWorkspaceId(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID: UUID?] {
        let liveWorkspaceIds = Set(tabs.map(\.id))
        let renderableGroupIds = Set(groupsById.values.compactMap { group in
            if group.isEmpty { return group.id }
            guard let liveAnchorId = group.liveAnchorWorkspaceId,
                  liveWorkspaceIds.contains(liveAnchorId) else {
                return nil
            }
            return group.id
        })
        let groupIdByLiveAnchor = groupsById.values
            .filter { renderableGroupIds.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .reduce(into: [UUID: UUID]()) { result, group in
                guard let liveAnchorId = group.liveAnchorWorkspaceId,
                      result[liveAnchorId] == nil else { return }
                result[liveAnchorId] = group.id
            }
        return Dictionary(uniqueKeysWithValues: tabs.map { tab in
            let effectiveGroupId = groupIdByLiveAnchor[tab.id]
                ?? tab.groupId.flatMap { renderableGroupIds.contains($0) ? $0 : nil }
            return (tab.id, effectiveGroupId)
        })
    }

    /// Builds the member index using effective, renderable group membership.
    static func memberWorkspaceIdsByGroupId(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]?,
        effectiveMembership: [UUID: UUID?]? = nil
    ) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        let effectiveMembershipByWorkspaceId = effectiveMembership
            ?? groupsById.map { effectiveGroupIdByWorkspaceId(tabs: tabs, groupsById: $0) }
        for tab in tabs {
            let groupId: UUID?
            if let effectiveMembershipByWorkspaceId {
                groupId = effectiveMembershipByWorkspaceId[tab.id] ?? nil
            } else {
                groupId = tab.groupId
            }
            if let groupId {
                result[groupId, default: []].append(tab.id)
            }
        }
        return result
    }
}
