internal import Foundation

/// Cross-computer presentation order for
/// ``MobileWorkspaceSortMode/recentActivity``.
///
/// This runs at the presentation layer, not in the aggregation: time
/// interleaving must not rewrite the Mac's spatial order (group anchors and move
/// RPCs depend on it). The list instead sorts immutable display blocks while
/// preserving every group's incoming member order.
public struct MobileWorkspaceRecencyOrder: Sendable {
    private struct GroupMembers {
        var workspaces: [MobileWorkspacePreview]
        let firstWorkspaceIndex: Int
        var newestActivityAt: Date?
        var containsPinnedWorkspace: Bool

        mutating func append(_ workspace: MobileWorkspacePreview) {
            workspaces.append(workspace)
            if let activityAt = workspace.lastActivityAt,
               newestActivityAt.map({ activityAt > $0 }) ?? true {
                newestActivityAt = activityAt
            }
            containsPinnedWorkspace = containsPinnedWorkspace || workspace.isPinned
        }
    }

    private struct DisplayBlock {
        let group: MobileWorkspaceGroupPreview?
        let workspaces: [MobileWorkspacePreview]
        let newestActivityAt: Date?
        let isPinned: Bool
        let stableIndex: Int

        var items: [MobileWorkspaceListItem] {
            guard let group else {
                return workspaces.map { .workspace($0, indented: false) }
            }
            return MobileWorkspaceListItem.items(
                workspaces: workspaces,
                groups: [group]
            )
        }
    }

    /// Create a recency-order helper.
    public init() {}

    /// Pinned rows first (the flat list's standing rule), then most recent
    /// `lastActivityAt` first. Rows without a timestamp sort last, and every
    /// tie keeps the incoming order so the list cannot shuffle between
    /// refreshes of equal payloads.
    public func displayOrder(_ workspaces: [MobileWorkspacePreview]) -> [MobileWorkspacePreview] {
        workspaces.enumerated().sorted { lhs, rhs in
            if lhs.element.isPinned != rhs.element.isPinned {
                return lhs.element.isPinned
            }
            switch (lhs.element.lastActivityAt, rhs.element.lastActivityAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Build the grouped Recent Activity projection as atomic display blocks.
    ///
    /// A known group ranks by its newest workspace timestamp, then renders its
    /// header and members in the incoming sidebar order. Ungrouped workspaces
    /// rank independently. Missing timestamps sort last, and ties retain the
    /// first incoming block position. Pinned groups or workspaces retain the
    /// standing pinned-first behavior without splitting a group. A workspace
    /// whose group metadata is temporarily missing remains an ungrouped row;
    /// durable empty group metadata remains visible as a header-only block.
    ///
    /// - Parameters:
    ///   - workspaces: Workspaces in the aggregated sidebar order.
    ///   - groups: Group metadata from every visible computer.
    /// - Returns: Group headers and workspace rows in Recent Activity order.
    public func groupedDisplayItems(
        _ workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview]
    ) -> [MobileWorkspaceListItem] {
        let groupsByID = Dictionary(
            groups.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let groupsByAnchorID = Dictionary(
            groups.compactMap { group in
                group.liveAnchorWorkspaceID.map { ($0, group) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var membersByGroupID: [MobileWorkspaceGroupPreview.ID: GroupMembers] = [:]
        var ungroupedBlocks: [DisplayBlock] = []
        ungroupedBlocks.reserveCapacity(workspaces.count)

        for (index, workspace) in workspaces.enumerated() {
            let explicitGroupID = workspace.groupID.flatMap { groupID in
                groupsByID[groupID] == nil ? nil : groupID
            }
            let groupID = explicitGroupID ?? groupsByAnchorID[workspace.id]?.id
            guard let groupID else {
                ungroupedBlocks.append(DisplayBlock(
                    group: nil,
                    workspaces: [workspace],
                    newestActivityAt: workspace.lastActivityAt,
                    isPinned: workspace.isPinned,
                    stableIndex: index
                ))
                continue
            }

            var normalizedWorkspace = workspace
            normalizedWorkspace.groupID = groupID
            membersByGroupID[groupID, default: GroupMembers(
                workspaces: [],
                firstWorkspaceIndex: index,
                newestActivityAt: nil,
                containsPinnedWorkspace: false
            )].append(normalizedWorkspace)
        }

        var blocks = ungroupedBlocks
        blocks.reserveCapacity(ungroupedBlocks.count + membersByGroupID.count)
        var emittedGroupIDs = Set<MobileWorkspaceGroupPreview.ID>()
        for (groupIndex, group) in groups.enumerated() where emittedGroupIDs.insert(group.id).inserted {
            guard let members = membersByGroupID[group.id] else {
                guard group.isEmpty else { continue }
                blocks.append(DisplayBlock(
                    group: group,
                    workspaces: [],
                    newestActivityAt: nil,
                    isPinned: group.isPinned,
                    stableIndex: workspaces.count + groupIndex
                ))
                continue
            }
            blocks.append(DisplayBlock(
                group: group,
                workspaces: members.workspaces,
                newestActivityAt: members.newestActivityAt,
                isPinned: group.isPinned || members.containsPinnedWorkspace,
                stableIndex: members.firstWorkspaceIndex
            ))
        }

        return blocks.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            switch (lhs.newestActivityAt, rhs.newestActivityAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.stableIndex < rhs.stableIndex
            }
        }.flatMap(\.items)
    }
}
