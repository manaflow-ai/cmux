import CmuxWorkspaces
import Foundation

/// Stable, allocation-free identity for a `SidebarWorkspaceRenderItem`.
///
/// ForEach gathers row identifiers on every list diff, so the id must be cheap
/// to create and hash. The previous `String` form
/// (`"workspace.\(uuid.uuidString)"`) allocated and formatted a fresh string on
/// every getter call; with the sidebar re-diffing all rows per update it was the
/// hottest app-owned frame in the
/// https://github.com/manaflow-ai/cmux/issues/5764 livelock spindump. The case
/// keeps group headers and workspace rows from ever colliding on the same UUID.
enum SidebarWorkspaceRenderItemID: Hashable {
    case group(UUID)
    case workspace(UUID)
}

/// One drawable item in the workspace sidebar.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(WorkspaceGroup, memberWorkspaceIds: [UUID], depth: Int)
    case workspace(Workspace, depth: Int)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let group, _, _):
            return .group(group.id)
        case .workspace(let workspace, _):
            return .workspace(workspace.id)
        }
    }

    var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(let group, _, _):
            return group.anchorWorkspaceId
        case .workspace(let workspace, _):
            return workspace.id
        }
    }

    var depth: Int {
        switch self {
        case .groupHeader(_, _, let depth):
            return depth
        case .workspace(_, let depth):
            return depth
        }
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty else { return [] }
        let groups = Array(groupsById.values)
        var anchorGroupByWorkspaceId: [UUID: WorkspaceGroup] = [:]
        for group in groups where anchorGroupByWorkspaceId[group.anchorWorkspaceId] == nil {
            anchorGroupByWorkspaceId[group.anchorWorkspaceId] = group
        }
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) })
        let knownGroupIds = Set(groupsById.keys)
        var childGroupsByParentId: [UUID?: [WorkspaceGroup]] = [:]
        var parentGroupIdByGroupId: [UUID: UUID?] = [:]
        for group in groups {
            let parentId: UUID? = {
                guard let parentGroupId = group.parentGroupId,
                      parentGroupId != group.id,
                      knownGroupIds.contains(parentGroupId) else {
                    return nil
                }
                return parentGroupId
            }()
            parentGroupIdByGroupId[group.id] = parentId
            childGroupsByParentId[parentId, default: []].append(group)
        }
        for parentId in Array(childGroupsByParentId.keys) {
            childGroupsByParentId[parentId]?.sort {
                (tabIndexById[$0.anchorWorkspaceId] ?? Int.max) <
                    (tabIndexById[$1.anchorWorkspaceId] ?? Int.max)
            }
        }
        var directMemberWorkspaceIdsByGroupId: [UUID: [UUID]] = [:]
        for tab in tabs {
            if let gid = tab.groupId {
                directMemberWorkspaceIdsByGroupId[gid, default: []].append(tab.id)
            }
        }
        var subtreeWorkspaceIdsByGroupId: [UUID: [UUID]] = [:]
        func subtreeWorkspaceIds(for groupId: UUID, visiting: inout Set<UUID>) -> [UUID] {
            if let cached = subtreeWorkspaceIdsByGroupId[groupId] {
                return cached
            }
            guard visiting.insert(groupId).inserted else { return directMemberWorkspaceIdsByGroupId[groupId] ?? [] }
            var ids = directMemberWorkspaceIdsByGroupId[groupId] ?? []
            for childGroup in childGroupsByParentId[Optional(groupId)] ?? [] {
                ids.append(contentsOf: subtreeWorkspaceIds(for: childGroup.id, visiting: &visiting))
            }
            visiting.remove(groupId)
            var seenIds: Set<UUID> = []
            let deduped = ids.filter { seenIds.insert($0).inserted }
            subtreeWorkspaceIdsByGroupId[groupId] = deduped
            return deduped
        }

        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count)
        var emittedHeaders: Set<UUID> = []

        func normalizedParentGroupId(for groupId: UUID) -> UUID? {
            parentGroupIdByGroupId[groupId] ?? nil
        }

        func appendGroup(_ group: WorkspaceGroup, depth: Int) {
            guard emittedHeaders.insert(group.id).inserted else { return }
            var visiting: Set<UUID> = []
            let memberWorkspaceIds = subtreeWorkspaceIds(for: group.id, visiting: &visiting)
            items.append(.groupHeader(group, memberWorkspaceIds: memberWorkspaceIds, depth: depth))
            guard !group.isCollapsed else { return }
            appendChildren(of: group.id, depth: depth + 1)
        }

        func appendChildren(of parentGroupId: UUID?, depth: Int) {
            for tab in tabs {
                if let anchoredGroup = anchorGroupByWorkspaceId[tab.id],
                   normalizedParentGroupId(for: anchoredGroup.id) == parentGroupId {
                    appendGroup(anchoredGroup, depth: depth)
                    continue
                }
                if let parentGroupId {
                    guard tab.groupId == parentGroupId else { continue }
                    if groupsById[parentGroupId]?.anchorWorkspaceId == tab.id {
                        continue
                    }
                    items.append(.workspace(tab, depth: depth))
                } else if tab.groupId == nil {
                    items.append(.workspace(tab, depth: depth))
                }
            }
        }

        appendChildren(of: nil, depth: 0)
        return items
    }
}
