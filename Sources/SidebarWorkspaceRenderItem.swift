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
    case divider(divider: WorkspaceSidebarDivider)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId, _):
            return .group(groupId)
        case .workspace(let workspaceId):
            return .workspace(workspaceId)
        case .divider(let divider):
            return .divider(divider.id)
        }
    }

    var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(_, let anchorWorkspaceId):
            return anchorWorkspaceId
        case .workspace(let workspaceId):
            return workspaceId
        case .divider(let divider):
            return divider.id
        }
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        dividers: [WorkspaceSidebarDivider] = [],
        orderedGroups: [WorkspaceGroup]? = nil
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty || !groupsById.isEmpty else { return [] }
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count + dividers.count)
        let topLevelIdByWorkspaceId = Dictionary(
            tabs.map { tab in
                let topLevelId = tab.groupId
                    .flatMap { groupsById[$0]?.anchorWorkspaceId }
                    ?? tab.id
                return (tab.id, topLevelId)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Preserve the established tab-order projection (including the
        // defensive behavior for legacy non-contiguous group runs), then add
        // dividers at the end of each top-level block. Rebuilding groups from
        // a dictionary would silently move a split legacy run ahead of an
        // intervening ungrouped workspace.
        var lastEmittedGroupId: UUID? = nil
        var emittedHeaders: Set<UUID> = []
        var collapsedByGroupId: [UUID: Bool] = [:]
        var skipChildrenUntilNextGroup = false
        for tab in tabs {
            let groupId = tab.groupId
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
            // Anchor workspaces are represented exclusively by the group
            // header. Ordinary rows remain in their established tab order.
            if let groupId, let group = groupsById[groupId], group.anchorWorkspaceId == tab.id {
                continue
            }
            if groupId == nil || !skipChildrenUntilNextGroup {
                items.append(.workspace(workspaceId: tab.id))
            }
        }

        // Empty pinned groups have no tab row from which a header can be
        // discovered. Emit them as first-class header-only rows, keeping the
        // model's group order within each pin tier. Empty unpinned groups are
        // placed after live rows until an explicit mutation removes them.
        let ordered = orderedGroups
            ?? groupsById.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let memberGroupIds = Set(tabs.compactMap(\.groupId))
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let emptyGroups = ordered.filter { !memberGroupIds.contains($0.id) }
        var renderedItems = items
        if !emptyGroups.isEmpty {
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

            var projectedEmpty: [SidebarWorkspaceRenderItem] = []
            projectedEmpty.reserveCapacity(items.count + emptyGroups.count)
            for item in items {
                if case .groupHeader(let groupId, _) = item,
                   let preceding = emptyBeforeGroup[groupId] {
                    projectedEmpty.append(contentsOf: preceding.map {
                        .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
                    })
                }
                projectedEmpty.append(item)
            }
            if !trailingPinned.isEmpty {
                let firstUnpinnedIndex = projectedEmpty.firstIndex { item in
                    switch item {
                    case .groupHeader(let groupId, _):
                        return groupsById[groupId]?.isPinned == false
                    case .workspace(let workspaceId):
                        guard let workspace = tabsById[workspaceId] else { return false }
                        if let groupId = workspace.groupId,
                           let group = groupsById[groupId] {
                            return !group.isPinned
                        }
                        return !workspace.isPinned
                    case .divider:
                        return false
                    }
                } ?? projectedEmpty.count
                projectedEmpty.insert(contentsOf: trailingPinned.map {
                    .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
                }, at: firstUnpinnedIndex)
            }
            projectedEmpty.append(contentsOf: trailingUnpinned.map {
                .groupHeader(groupId: $0.id, anchorWorkspaceId: $0.anchorWorkspaceId)
            })
            renderedItems = projectedEmpty
        }

        guard !dividers.isEmpty else { return renderedItems }
        let dividerByAnchor = Dictionary(
            dividers.map { ($0.afterWorkspaceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let topLevelIdByRenderIndex = renderedItems.map { item -> UUID in
            switch item {
            case .groupHeader(_, let anchorWorkspaceId):
                return anchorWorkspaceId
            case .workspace(let workspaceId):
                return topLevelIdByWorkspaceId[workspaceId] ?? workspaceId
            case .divider(let divider):
                // No divider exists in `items` yet; retain a total switch for
                // future callers that may pass an already-projected list.
                return divider.id
            }
        }
        var lastIndexByTopLevelId: [UUID: Int] = [:]
        for (index, topLevelId) in topLevelIdByRenderIndex.enumerated() {
            lastIndexByTopLevelId[topLevelId] = index
        }
        var projected: [SidebarWorkspaceRenderItem] = []
        projected.reserveCapacity(renderedItems.count + dividers.count)
        for (index, item) in renderedItems.enumerated() {
            projected.append(item)
            let topLevelId = topLevelIdByRenderIndex[index]
            if lastIndexByTopLevelId[topLevelId] == index,
               let divider = dividerByAnchor[topLevelId] {
                projected.append(.divider(divider: divider))
            }
        }
        return projected
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
        var result: [UUID: [UUID]] = [:]
        for tab in tabs {
            if let groupId = tab.groupId {
                result[groupId, default: []].append(tab.id)
            }
        }
        return result
    }
}
