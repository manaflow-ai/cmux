import CmuxWorkspaces
import Foundation

/// One drawable item in the workspace sidebar.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(WorkspaceGroup, memberCount: Int, depth: Int)
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
        var directMemberCountByGroupId: [UUID: Int] = [:]
        for tab in tabs {
            if let gid = tab.groupId {
                directMemberCountByGroupId[gid, default: 0] += 1
            }
        }
        var subtreeMemberCountByGroupId: [UUID: Int] = [:]
        func subtreeMemberCount(for groupId: UUID, visiting: inout Set<UUID>) -> Int {
            if let cached = subtreeMemberCountByGroupId[groupId] {
                return cached
            }
            guard visiting.insert(groupId).inserted else { return directMemberCountByGroupId[groupId] ?? 0 }
            var count = directMemberCountByGroupId[groupId] ?? 0
            for childGroup in childGroupsByParentId[Optional(groupId)] ?? [] {
                count += subtreeMemberCount(for: childGroup.id, visiting: &visiting)
            }
            visiting.remove(groupId)
            subtreeMemberCountByGroupId[groupId] = count
            return count
        }

        enum ChildRow {
            case group(WorkspaceGroup)
            case workspace(Workspace)
        }

        func normalizedParentGroupId(for groupId: UUID) -> UUID? {
            parentGroupIdByGroupId[groupId] ?? nil
        }

        var childRowsByParentId: [UUID?: [ChildRow]] = [:]
        for tab in tabs {
            if let anchoredGroup = anchorGroupByWorkspaceId[tab.id] {
                childRowsByParentId[
                    normalizedParentGroupId(for: anchoredGroup.id),
                    default: []
                ].append(.group(anchoredGroup))
                continue
            }
            if let groupId = tab.groupId, let group = groupsById[groupId] {
                if group.anchorWorkspaceId == tab.id {
                    continue
                }
                childRowsByParentId[Optional(groupId), default: []].append(.workspace(tab))
            } else {
                childRowsByParentId[nil, default: []].append(.workspace(tab))
            }
        }

        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count)
        var emittedHeaders: Set<UUID> = []

        func appendGroup(_ group: WorkspaceGroup, depth: Int) {
            guard emittedHeaders.insert(group.id).inserted else { return }
            var visiting: Set<UUID> = []
            let memberCount = subtreeMemberCount(for: group.id, visiting: &visiting)
            items.append(.groupHeader(group, memberCount: memberCount, depth: depth))
            guard !group.isCollapsed else { return }
            appendChildren(of: group.id, depth: depth + 1)
        }

        func appendChildren(of parentGroupId: UUID?, depth: Int) {
            for row in childRowsByParentId[parentGroupId] ?? [] {
                switch row {
                case .group(let anchoredGroup):
                    appendGroup(anchoredGroup, depth: depth)
                case .workspace(let tab):
                    items.append(.workspace(tab, depth: depth))
                }
            }
        }

        appendChildren(of: nil, depth: 0)
        return items
    }
}
