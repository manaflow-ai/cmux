#if os(iOS)
import CmuxMobileShellModel
import Foundation

/// One immutable-baseline workspace drag.
///
/// UIKit reports hover destinations in the currently rendered row order. This
/// value translates those transient gaps back into the pre-drag index space
/// expected by the shared move policy, then materializes that policy's exact
/// predicted row order before the finger lifts.
struct WorkspaceListDragSession {
    struct Commit: Equatable {
        let sourceOffset: Int
        let destination: Int
    }

    let draggedItemID: String
    private(set) var visualItems: [WorkspaceListTableItem]
    private(set) var commit: Commit?

    private let baselineItems: [WorkspaceListTableItem]
    private let baselineContentItems: [WorkspaceListTableItem]
    private let baselineIndexByItemID: [String: Int]
    private let semanticItems: [MobileWorkspaceListItem]
    private let workspaces: [MobileWorkspacePreview]
    private let groups: [MobileWorkspaceGroupPreview]
    private let sourceOffset: Int
    private let chromePrefixCount: Int
    private let movedItemIDs: Set<String>
    private let movedWorkspaceID: MobileWorkspacePreview.ID

    init?(
        items: [WorkspaceListTableItem],
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        groupHasUnreadByID: [MobileWorkspaceGroupPreview.ID: Bool],
        sourceTableRow: Int
    ) {
        let chromePrefixCount = items.prefix { item in
            if case .chrome = item { return true }
            return false
        }.count
        let sourceOffset = sourceTableRow - chromePrefixCount
        let contentItems = Array(items.dropFirst(chromePrefixCount))
        guard contentItems.indices.contains(sourceOffset) else { return nil }

        let workspacesByID = Dictionary(
            workspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let groupsByID = Dictionary(
            groups.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let semanticItems = Self.semanticItems(
            for: contentItems,
            workspacesByID: workspacesByID,
            groupsByID: groupsByID,
            groupHasUnreadByID: groupHasUnreadByID
        )
        guard semanticItems.count == contentItems.count else { return nil }
        guard let draggedContent = Self.draggedContent(
            sourceItem: semanticItems[sourceOffset],
            sourceID: contentItems[sourceOffset].id,
            contentItems: contentItems,
            workspacesByID: workspacesByID
        ) else { return nil }

        self.draggedItemID = contentItems[sourceOffset].id
        self.visualItems = items
        self.commit = nil
        self.baselineItems = items
        self.baselineContentItems = contentItems
        self.baselineIndexByItemID = Dictionary(
            contentItems.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        self.semanticItems = semanticItems
        self.workspaces = workspaces
        self.groups = groups
        self.sourceOffset = sourceOffset
        self.chromePrefixCount = chromePrefixCount
        self.movedItemIDs = draggedContent.itemIDs
        self.movedWorkspaceID = draggedContent.workspaceID
    }

    /// Updates the preview for UIKit's current insertion row.
    ///
    /// - Returns: `true` only when the visible row order or commit changed.
    @discardableResult
    mutating func update(destinationTableRow: Int) -> Bool {
        let destination = baselineDestination(forTableRow: destinationTableRow)
        let nextCommit: Commit?
        let nextItems: [WorkspaceListTableItem]

        if destination == sourceOffset || destination == sourceOffset + 1 {
            nextCommit = nil
            nextItems = baselineItems
        } else if let intent = semanticItems.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: sourceOffset),
            destination: destination
        ) {
            let predictedWorkspaces = workspaces.applyingWorkspaceMoveIntent(
                intent,
                movedWorkspaceID: movedWorkspaceID,
                groups: groups
            )
            let predictedContent = MobileWorkspaceListItem.items(
                workspaces: predictedWorkspaces,
                groups: groups
            ).map(Self.tableItem)
            nextCommit = Commit(
                sourceOffset: sourceOffset,
                destination: destination
            )
            nextItems = Array(baselineItems.prefix(chromePrefixCount))
                + predictedContent
        } else {
            nextCommit = nil
            nextItems = baselineItems
        }

        guard Self.presentationKeys(visualItems) != Self.presentationKeys(nextItems)
            || commit != nextCommit else {
            return false
        }
        visualItems = nextItems
        commit = nextCommit
        return true
    }

    @discardableResult
    mutating func resetPreview() -> Bool {
        guard Self.presentationKeys(visualItems) != Self.presentationKeys(baselineItems)
            || commit != nil else { return false }
        visualItems = baselineItems
        commit = nil
        return true
    }

    func isCompatible(
        with items: [WorkspaceListTableItem],
        workspaces nextWorkspaces: [MobileWorkspacePreview],
        groups nextGroups: [MobileWorkspaceGroupPreview]
    ) -> Bool {
        items.map(\.id) == baselineItems.map(\.id)
            && Self.workspacePolicyKeys(nextWorkspaces)
                == Self.workspacePolicyKeys(workspaces)
            && Self.groupPolicyKeys(nextGroups) == Self.groupPolicyKeys(groups)
    }

    private func baselineDestination(forTableRow tableRow: Int) -> Int {
        let visualContent = Array(visualItems.dropFirst(chromePrefixCount))
        let visualRow = min(
            max(tableRow - chromePrefixCount, visualContent.startIndex),
            visualContent.endIndex
        )
        guard visualRow < visualContent.endIndex else {
            return baselineContentItems.endIndex
        }

        // A predicted move can add or remove a synthetic group footer. Walk to
        // the next durable, non-moved row so every hover gap still maps to the
        // original index space.
        for item in visualContent[visualRow...] where !movedItemIDs.contains(item.id) {
            if let index = baselineIndexByItemID[item.id] {
                return index
            }
        }
        return baselineContentItems.endIndex
    }

    private static func tableItem(_ item: MobileWorkspaceListItem) -> WorkspaceListTableItem {
        switch item {
        case .workspace(let workspace, let indented):
            .workspace(workspace.id, indented: indented)
        case .groupHeader(let group, _):
            .groupHeader(group.id)
        case .groupFooter(let groupID):
            .groupFooter(groupID)
        }
    }

    private static func semanticItems(
        for items: [WorkspaceListTableItem],
        workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview],
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview],
        groupHasUnreadByID: [MobileWorkspaceGroupPreview.ID: Bool]
    ) -> [MobileWorkspaceListItem] {
        items.compactMap { item in
            switch item {
            case .workspace(let workspaceID, let indented):
                workspacesByID[workspaceID].map {
                    .workspace($0, indented: indented)
                }
            case .groupHeader(let groupID):
                groupsByID[groupID].map {
                    .groupHeader(
                        $0,
                        hasUnread: groupHasUnreadByID[groupID, default: false]
                    )
                }
            case .groupFooter(let groupID):
                .groupFooter(groupID)
            case .chrome, .filterEmpty:
                nil
            }
        }
    }

    private static func draggedContent(
        sourceItem: MobileWorkspaceListItem,
        sourceID: String,
        contentItems: [WorkspaceListTableItem],
        workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview]
    ) -> DraggedContent? {
        switch sourceItem {
        case .workspace(let workspace, _):
            DraggedContent(workspaceID: workspace.id, itemIDs: [sourceID])
        case .groupHeader(let group, _):
            DraggedContent(
                workspaceID: group.anchorWorkspaceID,
                itemIDs: Set(contentItems.compactMap { item in
                    draggedGroupItemID(
                        item,
                        groupID: group.id,
                        workspacesByID: workspacesByID
                    )
                })
            )
        case .groupFooter:
            nil
        }
    }

    private static func draggedGroupItemID(
        _ item: WorkspaceListTableItem,
        groupID: MobileWorkspaceGroupPreview.ID,
        workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview]
    ) -> String? {
        switch item {
        case .groupHeader(let itemGroupID), .groupFooter(let itemGroupID):
            itemGroupID == groupID ? item.id : nil
        case .workspace(let workspaceID, _):
            workspacesByID[workspaceID]?.groupID == groupID ? item.id : nil
        case .chrome, .filterEmpty:
            nil
        }
    }

    private static func workspacePolicyKeys(
        _ workspaces: [MobileWorkspacePreview]
    ) -> [WorkspacePolicyKey] {
        workspaces.map {
            WorkspacePolicyKey(id: $0.id, groupID: $0.groupID, isPinned: $0.isPinned)
        }
    }

    private static func groupPolicyKeys(
        _ groups: [MobileWorkspaceGroupPreview]
    ) -> [GroupPolicyKey] {
        groups.map {
            GroupPolicyKey(
                id: $0.id,
                anchorWorkspaceID: $0.anchorWorkspaceID,
                isCollapsed: $0.isCollapsed,
                isPinned: $0.isPinned
            )
        }
    }

    private static func presentationKeys(
        _ items: [WorkspaceListTableItem]
    ) -> [PresentationKey] {
        items.map {
            PresentationKey(id: $0.id, isIndented: $0.isIndentedWorkspace)
        }
    }

}

private extension WorkspaceListDragSession {
    struct PresentationKey: Equatable {
        let id: String
        let isIndented: Bool
    }

    struct WorkspacePolicyKey: Equatable {
        let id: MobileWorkspacePreview.ID
        let groupID: MobileWorkspaceGroupPreview.ID?
        let isPinned: Bool
    }

    struct GroupPolicyKey: Equatable {
        let id: MobileWorkspaceGroupPreview.ID
        let anchorWorkspaceID: MobileWorkspacePreview.ID
        let isCollapsed: Bool
        let isPinned: Bool
    }

    struct DraggedContent {
        let workspaceID: MobileWorkspacePreview.ID
        let itemIDs: Set<String>
    }
}
#endif
